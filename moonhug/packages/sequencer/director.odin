package sequencer

// PlayableDirector runtime: advances time, then drives every track through
// its registered Track_Desc — build once per (director, track), tick with
// the frame's time window, destroy with the director. No track kind is
// special here: the animation track registers itself like audio and
// particles do.
//
// Evaluation is a pure function of director time, so scrubbing is
// director_set_time — the sequencer window's preview and a future nested
// Control Track both ride it.

import "core:math"
import "moonhug:engine"

@(update={order=2})
directors_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(playable_directors(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(d.owner)) do continue
		if !engine.transform_active_in_hierarchy(d.owner) do continue
		director_tick(d, dt)
	}
}

// --- Playback control (Unity's Play/Pause/Stop) --------------------------------

director_play :: proc(d: ^PlayableDirector) {
	d.started = true
	d.playing = true
}

director_pause :: proc(d: ^PlayableDirector) {
	d.playing = false
}

director_stop :: proc(d: ^PlayableDirector) {
	d.playing = false
	d.time = 0
	d.prev_time = 0
}

// One director's advance — public so tests drive it without a frame loop.
director_tick :: proc(d: ^PlayableDirector, dt: f32) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	if !d.started {
		d.started = true
		d.playing = !d.manual_start
	}
	if !d.playing do return
	_director_ensure_built(d, tl)

	speed := d.speed if d.speed > 0 else 1
	d.prev_time = d.time
	d.time += dt * speed

	wrapped := false
	dur := timeline_duration(tl)
	if dur > 0 {
		switch d.wrap {
		case .Loop:
			if d.time >= dur {
				d.time = math.mod(d.time, dur)
				wrapped = true
			}
		case .Once:
			if d.time >= dur {
				d.time = dur
				d.playing = false
			}
		}
	}
	_director_evaluate(d, tl, wrapped, scrub = false)
}

// Jump to a time and evaluate — the scrub path. Stateful tracks see
// scrub=true and reset instead of firing crossings.
director_set_time :: proc(d: ^PlayableDirector, time: f32) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	_director_ensure_built(d, tl)
	d.prev_time = time
	d.time = time
	_director_evaluate(d, tl, wrapped = false, scrub = true)
}

// The editor preview's PLAY advance: evaluation keeps scrub semantics (the
// world stays a pure function of time — particles replay, poses restore per
// frame) but crossings are real (ctx.playing), so audio plays live like
// Unity's Timeline preview. `time` moving backwards is read as the preview
// loop wrapping — jumps use director_set_time.
director_preview_step :: proc(d: ^PlayableDirector, time: f32) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	_director_ensure_built(d, tl)
	d.prev_time = d.time
	d.time = time
	wrapped := time < d.prev_time
	_director_evaluate(d, tl, wrapped, scrub = true, playing = true)
}

// Quiet every track the director drives — the editor calls it when its
// preview stops (each kind knows what "quiet" means for its target).
// `playing` marks the PER-FRAME restore of an auto-advancing preview:
// world-state restores (poses, activation) still run, but tracks whose
// preview effect must persist across frames (an audio voice) skip quieting
// until the preview truly stops.
director_preview_end :: proc(d: ^PlayableDirector, playing := false) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	for &track, ti in tl.tracks {
		desc, has := track_desc(track.kind)
		if !has || desc.preview_end == nil do continue
		ctx := _director_ctx(d, tl, &track, i32(ti), scrub = true, playing = playing)
		desc.preview_end(&ctx)
	}
}

// Free every track's state; the next tick rebuilds. Structural timeline
// edits and component cleanup both land here.
director_teardown :: proc(d: ^PlayableDirector) {
	tl, has_tl := timeline_load(engine.Asset_GUID(d.timeline.guid))
	for state, ti in d.track_states {
		if state == nil do continue
		if !has_tl || ti >= len(tl.tracks) do continue
		if desc, has := track_desc(tl.tracks[ti].kind); has && desc.destroy != nil {
			desc.destroy(state)
		}
	}
	delete(d.track_states)
	d.track_states = nil
	d.built = false
}

// Tear down built state of every director playing `guid` — structural
// timeline edits (tracks/clips added or removed) rebuild on the next tick.
directors_invalidate :: proc(guid: engine.Asset_GUID) {
	w := engine.ctx_world()
	if w == nil do return
	it := engine.pool_iterator(playable_directors(w))
	for d, _ in engine.pool_next(&it) {
		if engine.Asset_GUID(d.timeline.guid) != guid || !d.built do continue
		director_teardown(d)
	}
}

@(private = "file")
_director_ensure_built :: proc(d: ^PlayableDirector, tl: ^Timeline) {
	if d.built do return
	d.built = true
	d.track_states = make([dynamic]rawptr, len(tl.tracks))
	for &track, ti in tl.tracks {
		desc, has := track_desc(track.kind)
		if !has || desc.build == nil do continue
		ctx := _director_ctx(d, tl, &track, i32(ti), scrub = false)
		d.track_states[ti] = desc.build(&ctx)
	}
}

@(private = "file")
_director_ctx :: proc(
	d: ^PlayableDirector,
	tl: ^Timeline,
	track: ^Timeline_Track,
	ti: i32,
	scrub: bool,
	wrapped := false,
	playing := false,
) -> Track_Ctx {
	state: rawptr
	if int(ti) < len(d.track_states) do state = d.track_states[ti]
	return Track_Ctx{
		track     = track,
		target    = director_binding(d, ti),
		owner     = engine.Transform_Handle(d.owner),
		state     = state,
		prev_time = d.prev_time,
		time      = d.time,
		wrapped   = wrapped,
		duration  = timeline_duration(tl),
		scrub     = scrub,
		playing   = playing,
	}
}

@(private = "file")
_director_evaluate :: proc(d: ^PlayableDirector, tl: ^Timeline, wrapped: bool, scrub: bool, playing := false) {
	for &track, ti in tl.tracks {
		if track.muted do continue
		desc, has := track_desc(track.kind)
		if !has || desc.tick == nil do continue
		ctx := _director_ctx(d, tl, &track, i32(ti), scrub, wrapped, playing)
		desc.tick(&ctx)
	}
}

// The scene target bound to a track, or the zero ref.
director_binding :: proc(d: ^PlayableDirector, track: i32) -> engine.Ref_Local {
	for &b in d.bindings {
		if b.track == track do return b.target
	}
	return {}
}
