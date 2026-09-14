package animation

// Import settings for a clip (docs/AnimationComponent.md). These live in the
// asset's .meta, never in the .anim itself, because a clip extracted from a
// model is a GENERATED file: re-extracting rewrites it, and anything authored
// must survive that. The meta is a separate file, so it does.
//
// The importer bakes these into the artifact, so the runtime reads a clip that
// already has them and never opens a meta.
//
// Settings NOT here, and why — a knob that does nothing is worse than a missing
// one:
// - Mirror needs a left/right bone mapping (an avatar). There is none.
// - Root motion (bake into pose, orientation and Y/XZ offsets, height from
//   feet) needs a root-motion system. There is none.
// - Additive reference pose needs additive layers. Layers here override, they
//   do not add.
// Each becomes worth adding the day the system behind it exists.

@(typ_guid={guid = "6b1f9d3a-7c42-4e85-b0a6-1d28e5f47c93", makeProcName=make_pAnimation_Clip_Settings})
Animation_Clip_Settings :: struct {
	// Once holds the final pose, Loop restarts. Every state defaults to this
	// and may override it per state (Animation_Entry.wrap).
	wrap: Animation_Wrap,

	// Frames per second the editor snaps keys and the playhead to. Authoring
	// only — evaluation is continuous in seconds. 0 means the default.
	frame_rate: f32,

	// Where in the cycle sampling starts, as a fraction of the clip: 0.5 begins
	// halfway through. Two characters sharing one walk stop marching in step
	// when their offsets differ. Only meaningful for a looping clip, since a
	// Once clip started mid-way would simply miss its beginning.
	cycle_offset: f32,

	// Sub-range to keep, in seconds of the SOURCE clip. The importer trims the
	// keys and rebases the times, so the artifact is the trimmed clip and
	// nothing pays for it at runtime. stop <= start means the whole clip.
	trim_start: f32,
	trim_stop:  f32,
}

make_pAnimation_Clip_Settings :: proc() -> any {
	p := new(Animation_Clip_Settings)
	p.frame_rate = ANIMATION_FRAME_RATE_DEFAULT
	return p^
}

// The sample time for a clip node: the driver's time, shifted by the clip's
// cycle offset and wrapped back into the clip.
//
// Applied HERE, at the one place every path samples a clip — the driver, the
// editor preview and a timeline's animation track all set a node's time and
// arrive at this evaluation — so the offset needs no cooperation from any of
// them.
animation_clip_sample_time :: proc(clip: ^AnimationClip, t: f32) -> f32 {
	if clip == nil || clip.cycle_offset == 0 || clip.length <= 0 do return t
	if clip.wrap != .Loop do return t
	shifted := t + clip.cycle_offset * clip.length
	wrapped, _ := animation_wrap_time(shifted, clip.length, .Loop)
	return wrapped
}

// Apply settings to a clip in place: the fields the runtime reads, then the
// trim. Called by the importer, which then writes the result as the artifact.
animation_clip_apply_settings :: proc(clip: ^AnimationClip, s: Animation_Clip_Settings) {
	clip.wrap = s.wrap
	clip.frame_rate = s.frame_rate
	clip.cycle_offset = s.cycle_offset
	_animation_clip_trim(clip, s.trim_start, s.trim_stop)
}

// Keep only `start..stop` and rebase to 0. A channel keeps an interpolated key
// at each edge, so a trim that cuts between keys still starts and ends on the
// value the clip actually had there rather than on the nearest key.
@(private = "file")
_animation_clip_trim :: proc(clip: ^AnimationClip, start, stop: f32) {
	if stop <= start do return
	lo := max(start, 0)
	hi := min(stop, clip.length)
	if hi <= lo do return

	for &ch in clip.channels {
		if len(ch.times) == 0 do continue
		edge_lo := _animation_channel_sample(&ch, lo)
		edge_hi := _animation_channel_sample(&ch, hi)

		times := make([dynamic]f32)
		values := make([dynamic][4]f32)
		append(&times, 0)
		append(&values, edge_lo)
		for t, i in ch.times {
			if t <= lo || t >= hi do continue
			append(&times, t - lo)
			append(&values, ch.values[i])
		}
		append(&times, hi - lo)
		append(&values, edge_hi)

		delete(ch.times)
		delete(ch.values)
		ch.times = times
		ch.values = values
	}
	clip.length = hi - lo
}
