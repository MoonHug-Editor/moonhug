package sequencer

// The sequencer's vocabulary (docs/Sequencer.md). A timeline is a TRANSFORM
// SUBTREE — a PlayableDirector node with TimelineTrack child nodes holding
// TimelineClip nodes — so there is no timeline document format: prefabs are
// the asset form, nesting is composition, variants and overrides are the
// tweak surface. This file holds what track KINDS program against: the
// per-tick view structs, the evaluation-mode vocabulary, and the Track_Desc
// registry every kind (animation included) registers through, so this
// package imports none of them.

import "base:runtime"
import "core:strings"
import "moonhug:engine"

// A clip as track hooks see it, materialized from a clip NODE each tick.
// `name` borrows the node's name (markers fire it), `node` addresses the
// clip for editor selection and the control track's nested content.
Timeline_Clip :: struct {
	start:    f32,
	duration: f32,
	ease_in:  f32,
	ease_out: f32,
	speed:    f32, // clip-local time scale, 0 behaves as 1
	asset:    engine.Asset_GUID,
	name:     string,
	node:     engine.Transform_Handle,
}

// A track as hooks see it, materialized from a track NODE each tick. Clips
// are sorted by start. Strings borrow the live components — the view lives
// for one evaluation (temp-allocated by director_tracks).
Timeline_Track :: struct {
	kind:   string,
	name:   string,
	muted:  bool,
	target: engine.Ref_Local,
	node:   engine.Transform_Handle,
	clips:  []Timeline_Clip,
}

// --- Track registry -----------------------------------------------------------------

// What a registered track's hooks see: the time window this frame moved
// through, the track's target, and the kind's own state.
Track_Ctx :: struct {
	track:     ^Timeline_Track,
	target:    engine.Ref_Local, // the track component's target, pre-resolved
	owner:     engine.Transform_Handle, // the director's transform
	state:     rawptr, // whatever Track_Desc.build returned
	prev_time: f32,
	time:      f32,
	wrapped:   bool, // the loop wrapped inside this tick
	duration:  f32,  // the timeline's playable length
	mode:      Track_Mode,
}

// How the director's time advanced this evaluation. Each track kind decides
// what a mode means for its target:
// - Play: the runtime. Crossings fire, side effects are real.
// - Scrub: time jumped (ruler drag, paused playhead). Stateful tracks reset
//   and replay deterministically instead of crossing; nothing sounds.
// - Preview_Play: the editor preview auto-advances. Crossings are real and
//   audio plays live (Unity's Timeline preview), particles keep their
//   deterministic replay, and hooks into game code (markers) stay silent.
Track_Mode :: enum u8 {
	Play,
	Scrub,
	Preview_Play,
}

// Wrap-aware "did playback cross `at` this tick" — the half-open [prev, time)
// window, split in two when the loop wrapped (the burst-trigger pattern).
track_crossed :: proc(ctx: ^Track_Ctx, at: f32) -> bool {
	if ctx.mode == .Scrub do return false
	if !ctx.wrapped do return at >= ctx.prev_time && at < ctx.time
	return (at >= ctx.prev_time && at < ctx.duration) || (at >= 0 && at < ctx.time)
}

// Whether playback time sits inside the clip's span.
track_clip_active :: proc(ctx: ^Track_Ctx, c: ^Timeline_Clip) -> bool {
	return ctx.time >= c.start && ctx.time < c.start + c.duration
}

Track_Desc :: struct {
	kind:         string,
	binding_type: string, // component/transform type the track binds ("" = none)

	// Per-director lifecycle. `build` runs once per (director, track) and
	// returns the kind's own state — nil when it needs none; `destroy` frees
	// it. `preview_end` quiets whatever the track was driving when the
	// editor's preview stops (the registry's answer to "the window must not
	// import every track's package").
	build:       proc(ctx: ^Track_Ctx) -> rawptr,
	destroy:     proc(state: rawptr),
	tick:        proc(ctx: ^Track_Ctx),
	preview_end: proc(ctx: ^Track_Ctx),
}

_track_registry: map[string]Track_Desc

// Process-global registry: never borrows the caller's allocator (same rule
// as every registry — a test's tracking allocator would dangle).
track_register :: proc(desc: Track_Desc) {
	context.allocator = runtime.default_allocator()
	if _track_registry == nil do _track_registry = make(map[string]Track_Desc)
	_track_registry[strings.clone(desc.kind)] = desc
}

track_desc :: proc(kind: string) -> (Track_Desc, bool) {
	d, ok := _track_registry[kind]
	return d, ok
}

// Registered kind names, sorted — the window's Add Track menu.
track_kinds :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(_track_registry), allocator)
	for kind in _track_registry do append(&out, kind)
	_sort_strings(out[:])
	return out[:]
}

@(private = "file")
_sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) {
		for j := i; j > 0 && s[j] < s[j - 1]; j -= 1 {
			s[j], s[j - 1] = s[j - 1], s[j]
		}
	}
}

// --- Built-in registry tracks ---------------------------------------------------------

// Activation: the bound transform is active while any clip covers the time
// (Unity's activation track post-behavior "inactive outside clips").
//
// The track owns its preview restore: outside Play mode the tick captures
// the pre-tick is_active, and preview_end (the editor's per-frame render
// restore) writes it back — the world returns to whatever the user authored,
// including authored-INACTIVE objects.
@(private = "file")
_Activation_State :: struct {
	captured:   bool,
	was_active: bool,
}

@(private = "file")
_activation_track_build :: proc(ctx: ^Track_Ctx) -> rawptr {
	return new(_Activation_State)
}

@(private = "file")
_activation_track_destroy :: proc(state: rawptr) {
	free(state)
}

_activation_track_tick :: proc(ctx: ^Track_Ctx) {
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, ctx.target.handle) do return
	t := engine.pool_get(&w.transforms, ctx.target.handle)
	if t == nil do return
	if st := cast(^_Activation_State)ctx.state; st != nil && ctx.mode != .Play && !st.captured {
		st.captured = true
		st.was_active = t.is_active
	}
	active := false
	for &c in ctx.track.clips {
		if track_clip_active(ctx, &c) do active = true
	}
	t.is_active = active
}

// Write back the pre-tick state the tick captured — the editor never leaves
// an object flipped, whichever way it was authored.
@(private = "file")
_activation_preview_end :: proc(ctx: ^Track_Ctx) {
	st := cast(^_Activation_State)ctx.state
	if st == nil || !st.captured do return
	st.captured = false
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, ctx.target.handle) do return
	if t := engine.pool_get(&w.transforms, ctx.target.handle); t != nil do t.is_active = st.was_active
}

// Markers: zero-duration clips fire the hook when playback crosses them.
// The hook is game/editor code's to install.
timeline_marker_hook: proc(name: string, target: engine.Ref_Local)

_marker_track_tick :: proc(ctx: ^Track_Ctx) {
	if timeline_marker_hook == nil do return
	// Never from the editor preview, playing or not — marker hooks are game
	// code (Unity does not fire signals in preview either).
	if ctx.mode != .Play do return
	for &c in ctx.track.clips {
		if track_crossed(ctx, c.start) {
			timeline_marker_hook(c.name, ctx.target)
		}
	}
}

// Control: each clip plays a NESTED TIMELINE — the clip node's child subtree
// holding its own PlayableDirector (a nested timeline prefab instance, per
// the timeline-as-prefab model). Inside the span the child evaluates at the
// clip-local time with the parent's mode; outside it rests at 0 with scrub
// semantics (quiet, deterministic).
_control_track_tick :: proc(ctx: ^Track_Ctx) {
	for &c in ctx.track.clips {
		child := _control_child_director(c.node)
		if child == nil do continue
		if track_clip_active(ctx, &c) {
			speed := c.speed if c.speed > 0 else 1
			director_evaluate_at(child, (ctx.time - c.start) * speed, ctx.mode)
		} else {
			director_evaluate_at(child, 0, .Scrub)
		}
	}
}

@(private = "file")
_control_track_preview_end :: proc(ctx: ^Track_Ctx) {
	for &c in ctx.track.clips {
		if child := _control_child_director(c.node); child != nil {
			director_preview_end(child, ctx.mode == .Preview_Play)
		}
	}
}

// The first PlayableDirector in the clip node's direct children — the root
// of the nested timeline instance placed under the clip.
@(private = "file")
_control_child_director :: proc(clip_node: engine.Transform_Handle) -> ^PlayableDirector {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(clip_node))
	if t == nil do return nil
	for child in t.children {
		_, d := get_comp(engine.Transform_Handle(child.handle), PlayableDirector)
		if d != nil do return d
	}
	return nil
}

@(private = "file") _builtin_tracks_registered: bool

register_builtin_tracks :: proc() {
	if _builtin_tracks_registered do return
	_builtin_tracks_registered = true
	track_register(Track_Desc{
		kind         = "activation",
		binding_type = "Transform",
		build        = _activation_track_build,
		destroy      = _activation_track_destroy,
		tick         = _activation_track_tick,
		preview_end  = _activation_preview_end,
	})
	track_register(Track_Desc{kind = "marker", binding_type = "Transform", tick = _marker_track_tick})
	track_register(Track_Desc{
		kind        = "control",
		tick        = _control_track_tick,
		preview_end = _control_track_preview_end,
	})
}

// ImportersInit is the asset-layer init phase both binaries run — the same
// slot the animation and audio packages use. Track-owning packages register
// at a LATER order, so the registry exists when they do.
@(phase={key=ImportersInit, order=3})
sequencer_package_init :: proc() {
	register_builtin_tracks()
}
