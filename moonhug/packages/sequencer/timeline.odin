package sequencer

// The sequencer's vocabulary (docs/Sequencer.md). A timeline is a TRANSFORM
// SUBTREE — a PlayableDirector node with track child nodes holding clip
// nodes — so there is no timeline document format: prefabs are the asset
// form, nesting is composition, variants and overrides are the tweak
// surface. This file holds what track KINDS program against: the per-tick
// view structs, the evaluation-mode vocabulary, and the Track_Desc registry
// every kind (animation included) registers through, so this package
// imports none of them.
//
// A kind is a COMPONENT, not a name: the registry keys on the TypeKey of the
// component a track node carries beside its TimelineTrack. Hooks read their
// own component (and their clips' components) for targets and payloads.

import "base:runtime"
import "core:slice"
import "moonhug:engine"

// A clip as track hooks see it, materialized from a clip NODE each tick.
// `name` borrows the node's name (markers fire it); `node` addresses the
// clip so a hook can read its own kind component off it.
Clip_View :: struct {
	start:    f32,
	duration: f32,
	ease_in:  f32,
	ease_out: f32,
	speed:    f32, // clip-local time scale, 0 behaves as 1
	name:     string,
	node:     engine.Transform_Handle,
}

// A track as hooks see it, materialized from a track NODE each tick. Clips
// are sorted by start. The view lives for one evaluation (temp-allocated by
// director_tracks); `node` is where the kind component lives.
Track_View :: struct {
	kind:  engine.TypeKey, // the kind component's type key
	name:  string,
	muted: bool,
	node:  engine.Transform_Handle,
	clips: []Clip_View,
}

// --- Track registry -----------------------------------------------------------------

// What a registered track's hooks see: the time window this frame moved
// through, the track node (read your own component off it), and the kind's
// own state.
Track_Ctx :: struct {
	track:     ^Track_View,
	owner:     engine.Transform_Handle, // the director's transform
	state:     rawptr, // whatever Track_Desc.build returned
	prev_time: f32,
	time:      f32,
	wrapped:   bool, // the loop wrapped inside this tick
	duration:  f32,  // the timeline's playable length
	mode:      Track_Mode,
	play_id:   u32,  // the director's play-session counter (PlayableDirector)
}

// How the director's time advanced this evaluation. Each track kind decides
// what a mode means for its target:
// - Play: the runtime. Crossings fire, side effects are real.
// - Scrub: time jumped (ruler drag, paused playhead). Stateful tracks reset
//   and replay deterministically; nothing sounds.
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
track_clip_active :: proc(ctx: ^Track_Ctx, c: ^Clip_View) -> bool {
	return ctx.time >= c.start && ctx.time < c.start + c.duration
}

// A clip's blend weight at `t`, 0 outside its span (Unity's Timeline model).
//
// OVERLAP IS THE BLEND: where two clips on a track overlap, the earlier one
// ramps out across the overlap and the later one ramps in, so dropping a clip
// onto its neighbour's tail crossfades with no authoring. The blend is
// DERIVED from the spans — nothing is stored, so it can never disagree with
// where the clips actually sit.
//
// Explicit ease_in/ease_out still apply at boundaries with no neighbour (a
// clip fading up from nothing), and the shorter ramp wins where both exist.
// `clips` must be sorted by start, which director_tracks guarantees.
track_clip_weight :: proc(clips: []Clip_View, index: int, t: f32) -> f32 {
	if index < 0 || index >= len(clips) do return 0
	c := &clips[index]
	end := c.start + c.duration
	if t < c.start || t >= end do return 0

	in_ramp := c.ease_in
	out_ramp := c.ease_out

	// A previous clip reaching into this one: the overlap IS the ease-in.
	for i := index - 1; i >= 0; i -= 1 {
		p := &clips[i]
		p_end := p.start + p.duration
		if p_end <= c.start do continue
		if overlap := min(p_end, end) - c.start; overlap > 0 {
			in_ramp = max(in_ramp, overlap)
		}
		break
	}
	// A following clip reaching back into this one: the overlap is the
	// ease-out.
	for i := index + 1; i < len(clips); i += 1 {
		n := &clips[i]
		if n.start >= end do break
		if overlap := end - max(n.start, c.start); overlap > 0 {
			out_ramp = max(out_ramp, overlap)
		}
		break
	}

	w := f32(1)
	if in_ramp > 0 do w = min(w, (t - c.start) / in_ramp)
	if out_ramp > 0 do w = min(w, (end - t) / out_ramp)
	return clamp(w, 0, 1)
}

Track_Desc :: struct {
	// The kind's TRACK component: its TypeKey is the registry key and the
	// discriminator on a track node. `clip_key` is the kind's CLIP component,
	// added to every clip node the window creates on this track.
	track_key: engine.TypeKey,
	clip_key:  engine.TypeKey,
	label:     string, // menu/UI name

	// Clips are INSTANTS, not spans: created with zero duration and fired by
	// crossing rather than covering (markers). The window reads this instead
	// of naming a kind.
	instant: bool,

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

_track_registry: map[engine.TypeKey]Track_Desc

// Process-global registry: never borrows the caller's allocator (same rule
// as every registry — a test's tracking allocator would dangle).
track_register :: proc(desc: Track_Desc) {
	context.allocator = runtime.default_allocator()
	if _track_registry == nil do _track_registry = make(map[engine.TypeKey]Track_Desc)
	_track_registry[desc.track_key] = desc
}

track_desc :: proc(key: engine.TypeKey) -> (Track_Desc, bool) {
	d, ok := _track_registry[key]
	return d, ok
}

// Registered kinds, sorted by label — the window's Add Track menu.
track_kinds :: proc(allocator := context.temp_allocator) -> []Track_Desc {
	out := make([dynamic]Track_Desc, 0, len(_track_registry), allocator)
	for _, desc in _track_registry do append(&out, desc)
	slice.sort_by(out[:], proc(a, b: Track_Desc) -> bool { return a.label < b.label })
	return out[:]
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

@(private = "file")
_activation_track_tick :: proc(ctx: ^Track_Ctx) {
	_, at := get_comp(ctx.track.node, TrackActivation)
	if at == nil do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, at.target.handle) do return
	t := engine.pool_get(&w.transforms, at.target.handle)
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
	_, at := get_comp(ctx.track.node, TrackActivation)
	if at == nil do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, at.target.handle) do return
	if t := engine.pool_get(&w.transforms, at.target.handle); t != nil do t.is_active = st.was_active
}

// Markers: zero-duration clips fire the hook when playback crosses them.
// The hook is game/editor code's to install.
timeline_marker_hook: proc(name: string, target: engine.Ref_Local)

@(private = "file")
_marker_track_tick :: proc(ctx: ^Track_Ctx) {
	if timeline_marker_hook == nil do return
	// Never from the editor preview, playing or not — marker hooks are game
	// code (Unity does not fire signals in preview either).
	if ctx.mode != .Play do return
	_, mt := get_comp(ctx.track.node, TrackMarker)
	if mt == nil do return
	for &c in ctx.track.clips {
		if track_crossed(ctx, c.start) {
			timeline_marker_hook(c.name, mt.target)
		}
	}
}

// Control: each clip plays a NESTED TIMELINE — the clip node's child subtree
// holding its own PlayableDirector (a nested timeline prefab instance, per
// the timeline-as-prefab model). Inside the span the child evaluates at the
// clip-local time with the parent's mode; outside it rests at 0 with scrub
// semantics (quiet, deterministic).
@(private = "file")
_control_track_tick :: proc(ctx: ^Track_Ctx) {
	for &c in ctx.track.clips {
		child := _control_child_director(c.node)
		if child == nil do continue
		if track_clip_active(ctx, &c) {
			// A nested director never sees director_play — the span IS its
			// play. Entering it in Play mode starts a new session for the
			// child's tracks (per-play tween captures refresh).
			end := c.start + c.duration
			if ctx.mode == .Play && !(ctx.prev_time >= c.start && ctx.prev_time < end) {
				child.play_id += 1
			}
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
		track_key   = .TrackActivation,
		clip_key    = .ClipActivation,
		label       = "activation",
		build       = _activation_track_build,
		destroy     = _activation_track_destroy,
		tick        = _activation_track_tick,
		preview_end = _activation_preview_end,
	})
	track_register(Track_Desc{
		track_key = .TrackMarker,
		clip_key  = .ClipMarker,
		label     = "marker",
		instant   = true,
		tick      = _marker_track_tick,
	})
	track_register(Track_Desc{
		track_key   = .TrackControl,
		clip_key    = .ClipControl,
		label       = "control",
		tick        = _control_track_tick,
		preview_end = _control_track_preview_end,
	})
	track_register(_script_track_desc()) // component_script_track.odin
	track_register(_tween_track_desc())  // component_tween_track.odin
}

// ImportersInit is the asset-layer init phase both binaries run — the same
// slot the animation and audio packages use. Track-owning packages register
// at a LATER order, so the registry exists when they do.
@(phase={key=ImportersInit, order=3})
sequencer_package_init :: proc() {
	register_builtin_tracks()
}
