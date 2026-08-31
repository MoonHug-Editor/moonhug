package animation

// The animation timeline track (docs/Sequencer.md): clips are AnimationClips
// blended on a per-track mixer, weights from their ease ramps, so overlapping
// clips crossfade. The track drives an ANIMATION COMPONENT (Unity's model:
// the timeline takes over the Animator): its target names the Animation to
// play on, and the component's own playback stands down while the track
// drives it, so the two never write the same transforms in one frame.
// Unset, the track looks for an Animation on the director itself, and falls
// back to posing the director's transform directly when there is none.
//
// The track owns its playable graph as the director's per-track state — the
// sequencer package holds no animation knowledge, exactly like audio and
// particles.

import "moonhug:engine"
import seq "moonhug:packages/sequencer"

// The kind's components. The clip carries its .anim; the track carries the
// object those clips play on.
@(component)
@(typ_guid={guid = "89aaf6a3-5c2e-4af3-8893-81833e7f79b9"})
TrackAnimation :: struct {
	using base: engine.CompData `inspect:"-"`,

	// The Animation component this track drives — the object the clips play
	// on. Its own playback is suppressed while the track drives it. Unset =
	// the director's own object, which is what a timeline authored as a
	// self-contained prefab wants.
	target: engine.Ref_Local `ref:"Animation"`,
}

@(component)
@(typ_guid={guid = "d0b0e534-01d0-4b0f-9f2c-1e38daa94c3d"})
ClipAnimation :: struct {
	using base: engine.CompData `inspect:"-"`,

	clip: engine.Asset_GUID `ext:"anim"`,
}

// The .anim a timeline clip plays, or the empty guid.
@(private = "file")
_anim_clip_asset :: proc(c: ^seq.Clip_View) -> engine.Asset_GUID {
	if _, cr := get_comp(c.node, ClipAnimation); cr != nil do return cr.clip
	return {}
}

@(phase={key=ImportersInit, order=4})
animation_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	seq.track_register(seq.Track_Desc{
		track_key   = .TrackAnimation,
		clip_key    = .ClipAnimation,
		label       = "animation",
		build       = _animation_track_build,
		destroy     = _animation_track_destroy,
		tick        = _animation_track_tick,
		preview_end = _animation_track_preview_end,
	})
}

// One track's graph: a mixer fed by one clip node per timeline clip.
@(private = "file")
_Anim_Track :: struct {
	output: Playable_Output,
	mixer:  Playable_Handle,
	clips:  [dynamic]Playable_Handle,
	// The transform the binding was built against. The director's structural
	// fingerprint does not watch a kind's own fields, so the track notices
	// its own target moving and rebinds.
	root:   engine.Transform_Handle,
}

// The Animation component the track drives, or nil when it poses a bare
// transform instead (no target and none on the director).
@(private = "file")
_animation_track_comp :: proc(ctx: ^seq.Track_Ctx) -> ^Animation {
	w := engine.ctx_world()
	if _, at := get_comp(ctx.track.node, TrackAnimation); at != nil {
		if engine.world_pool_valid(w, at.target.handle) && at.target.handle.type_key == .Animation {
			return cast(^Animation)engine.world_pool_get(w, at.target.handle)
		}
	}
	// Unset: the director's own Animation, when it has one.
	_, a := get_comp(ctx.owner, Animation)
	return a
}

// The transform the track's clips animate: its driven component's owner, or
// the director when it drives none.
@(private = "file")
_animation_track_root :: proc(ctx: ^seq.Track_Ctx) -> engine.Transform_Handle {
	if a := _animation_track_comp(ctx); a != nil do return engine.Transform_Handle(a.owner)
	return ctx.owner
}

@(private = "file")
_animation_track_build :: proc(ctx: ^seq.Track_Ctx) -> rawptr {
	st := new(_Anim_Track)
	st.root = _animation_track_root(ctx)
	playable_output_init(&st.output, st.root)
	st.mixer = playable_add(&st.output.graph, Mixer_Playable{})
	st.output.graph.root = st.mixer
	st.clips = make([dynamic]Playable_Handle, 0, len(ctx.track.clips))
	for &c in ctx.track.clips {
		node := playable_add(&st.output.graph, Clip_Playable{clip = _anim_clip_asset(&c)})
		playable_connect(&st.output.graph, st.mixer, node, 0)
		append(&st.clips, node)
	}
	return st
}

@(private = "file")
_animation_track_destroy :: proc(state: rawptr) {
	st := cast(^_Anim_Track)state
	delete(st.clips)
	playable_output_destroy(&st.output)
	free(st)
}

@(private = "file")
_animation_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^_Anim_Track)ctx.state
	if st == nil do return
	// The driven component stands down: the track owns its object's pose for
	// as long as it is driving. Released in preview_end / on retarget.
	if a := _animation_track_comp(ctx); a != nil {
		a.timeline_driven = true
	}
	// Retarget: release the old object's pose before binding the new one, so
	// nothing is left frozen mid-animation.
	if root := _animation_track_root(ctx); root != st.root {
		animation_binding_write_defaults(&st.output.binding)
		animation_binding_destroy(&st.output.binding)
		animation_binding_init(&st.output.binding, root)
		st.root = root
	}
	for &c, ci in ctx.track.clips {
		if ci >= len(st.clips) do break
		w := seq.track_clip_weight(ctx.track.clips, ci, ctx.time)
		playable_set_input_weight(&st.output.graph, st.mixer, st.clips[ci], w)
		if w <= 0 do continue
		n := playable_node(&st.output.graph, st.clips[ci])
		if n == nil do continue
		local := (ctx.time - c.start) * (c.speed if c.speed > 0 else 1)
		// A source clip shorter than the timeline clip wraps by its own wrap
		// mode (Unity loops the source).
		if src, sok := animation_clip_load(_anim_clip_asset(&c)); sok {
			local, _ = animation_wrap_time(local, src.length, src.wrap)
		}
		n.time = local
	}
	playable_output_tick(&st.output)
}

// The editor's preview restores the authored pose through the same binding
// defaults the animation scrub preview uses.
@(private = "file")
_animation_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^_Anim_Track)ctx.state
	if st == nil do return
	animation_binding_write_defaults(&st.output.binding)
	// Hand the object back to its component.
	if a := _animation_track_comp(ctx); a != nil do a.timeline_driven = false
}

// The track's binding, for the editor's preview bracket: poses are captured
// before evaluation and restored after the render.
animation_track_binding :: proc(state: rawptr) -> ^Animation_Binding {
	st := cast(^_Anim_Track)state
	if st == nil do return nil
	return &st.output.binding
}
