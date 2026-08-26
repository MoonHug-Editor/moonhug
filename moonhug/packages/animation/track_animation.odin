package animation

// The animation timeline track (docs/Sequencer.md): clips are AnimationClips
// blended on a per-track mixer, weights from their ease ramps, so overlapping
// clips crossfade. Channel paths resolve under the DIRECTOR's transform, so
// this track binds nothing itself.
//
// The track owns its playable graph as the director's per-track state — the
// sequencer package holds no animation knowledge, exactly like audio and
// particles.

import seq "moonhug:packages/sequencer"

@(phase={key=ImportersInit, order=4})
animation_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	seq.track_register(seq.Track_Desc{
		kind        = "animation",
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
}

@(private = "file")
_animation_track_build :: proc(ctx: ^seq.Track_Ctx) -> rawptr {
	st := new(_Anim_Track)
	playable_output_init(&st.output, ctx.owner)
	st.mixer = playable_add(&st.output.graph, Mixer_Playable{})
	st.output.graph.root = st.mixer
	st.clips = make([dynamic]Playable_Handle, 0, len(ctx.track.clips))
	for &c in ctx.track.clips {
		node := playable_add(&st.output.graph, Clip_Playable{clip = c.asset})
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

// Ease-in/out weight ramp inside the clip's span, 0 outside. Overlapping
// clips crossfade through the mixer's normalization.
@(private = "file")
_clip_weight :: proc(c: ^seq.Timeline_Clip, t: f32) -> f32 {
	if t < c.start || t >= c.start + c.duration do return 0
	w := f32(1)
	if c.ease_in > 0 do w = min(w, (t - c.start) / c.ease_in)
	if c.ease_out > 0 do w = min(w, (c.start + c.duration - t) / c.ease_out)
	return clamp(w, 0, 1)
}

@(private = "file")
_animation_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^_Anim_Track)ctx.state
	if st == nil do return
	for &c, ci in ctx.track.clips {
		if ci >= len(st.clips) do break
		w := _clip_weight(&c, ctx.time)
		playable_set_input_weight(&st.output.graph, st.mixer, st.clips[ci], w)
		if w <= 0 do continue
		n := playable_node(&st.output.graph, st.clips[ci])
		if n == nil do continue
		local := (ctx.time - c.start) * (c.speed if c.speed > 0 else 1)
		// A source clip shorter than the timeline clip wraps by its own wrap
		// mode (Unity loops the source).
		if src, sok := animation_clip_load(c.asset); sok {
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
}

// The track's binding, for the editor's preview bracket: poses are captured
// before evaluation and restored after the render.
animation_track_binding :: proc(state: rawptr) -> ^Animation_Binding {
	st := cast(^_Anim_Track)state
	if st == nil do return nil
	return &st.output.binding
}
