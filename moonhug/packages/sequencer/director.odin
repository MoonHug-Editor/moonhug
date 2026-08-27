package sequencer

// PlayableDirector runtime: advances time, then drives every track in its
// SUBTREE through its registered Track_Desc — build once per (director,
// track), tick with the frame's time window, destroy with the director. No
// track kind is special here: the animation track registers itself like
// audio and particles do.
//
// The subtree IS the timeline (timeline-as-prefab): track nodes are the
// director transform's children, clip nodes theirs. Views materialize per
// evaluation (director_tracks); a structural fingerprint rebuilds track
// state when nodes change, so live edits need no explicit invalidation.
//
// Evaluation is a pure function of director time, so scrubbing is
// director_set_time — the sequencer window's preview and the control track
// both ride it.

import "core:math"
import "core:slice"
import "moonhug:engine"

@(update={order=2})
directors_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(playable_directors(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(d.owner)) do continue
		if !engine.transform_active_in_hierarchy(d.owner) do continue
		// A director nested under a control track's clip is DRIVEN, never
		// self-ticking — the parent timeline owns its time.
		if _director_is_control_driven(d) do continue
		director_tick(d, dt)
	}
}

// Whether an ancestor node carries a TimelineClip — the director sits inside
// a control track's clip and takes its time from the parent timeline.
@(private = "file")
_director_is_control_driven :: proc(d: ^PlayableDirector) -> bool {
	w := engine.ctx_world()
	cur := engine.Handle(d.owner)
	for {
		t := engine.pool_get(&w.transforms, cur)
		if t == nil || !engine.pool_valid(&w.transforms, t.parent.handle) do return false
		if _, c := get_comp(engine.Transform_Handle(t.parent.handle), TimelineClip); c != nil do return true
		cur = t.parent.handle
	}
}

// --- The subtree as track views -------------------------------------------------------

// Materialize the director's subtree into per-tick track views: each child
// node carrying a TimelineTrack, its clip-node children sorted by start.
// Strings borrow the live components; the slice lives on `allocator`.
director_tracks :: proc(d: ^PlayableDirector, allocator := context.temp_allocator) -> []Timeline_Track {
	w := engine.ctx_world()
	out := make([dynamic]Timeline_Track, allocator)
	owner := engine.pool_get(&w.transforms, engine.Handle(d.owner))
	if owner == nil do return out[:]
	for child in owner.children {
		tH := engine.Transform_Handle(child.handle)
		t := engine.pool_get(&w.transforms, child.handle)
		if t == nil do continue
		_, tc := get_comp(tH, TimelineTrack)
		if tc == nil do continue
		tv := Timeline_Track{
			kind   = tc.kind,
			name   = t.name,
			muted  = tc.muted,
			target = tc.target,
			node   = tH,
		}
		clips := make([dynamic]Timeline_Clip, allocator)
		for cn in t.children {
			cH := engine.Transform_Handle(cn.handle)
			ct := engine.pool_get(&w.transforms, cn.handle)
			if ct == nil do continue
			_, cc := get_comp(cH, TimelineClip)
			if cc == nil do continue
			append(&clips, Timeline_Clip{
				start    = cc.start,
				duration = cc.duration,
				ease_in  = cc.ease_in,
				ease_out = cc.ease_out,
				speed    = cc.speed,
				asset    = cc.asset,
				name     = ct.name,
				node     = cH,
			})
		}
		slice.sort_by(clips[:], proc(a, b: Timeline_Clip) -> bool { return a.start < b.start })
		tv.clips = clips[:]
		append(&out, tv)
	}
	return out[:]
}

// The playable length: authored on the director, or the last clip end.
director_duration :: proc(d: ^PlayableDirector, tracks: []Timeline_Track) -> f32 {
	if d.duration > 0 do return d.duration
	dur := f32(0)
	for &tv in tracks {
		for &c in tv.clips do dur = max(dur, c.start + c.duration)
	}
	return dur
}

// Structural fingerprint: which nodes make up the timeline and what each
// clip plays. A changed fingerprint tears down track state, so structural
// edits (window or hierarchy alike) rebuild without explicit invalidation.
// Field-only edits (times, eases, targets) keep the built state.
@(private = "file")
_director_tree_sig :: proc(tracks: []Timeline_Track) -> u64 {
	sig := u64(0xcbf29ce484222325)
	mix :: proc(sig: ^u64, v: u64) {
		sig^ = (sig^ ~ v) * 0x100000001b3
	}
	for &tv in tracks {
		mix(&sig, u64(engine.Handle(tv.node).index) | u64(engine.Handle(tv.node).generation) << 32)
		for ch in tv.kind do mix(&sig, u64(ch))
		for &c in tv.clips {
			mix(&sig, u64(engine.Handle(c.node).index) | u64(engine.Handle(c.node).generation) << 32)
			for b in ([16]u8)(c.asset) do mix(&sig, u64(b))
		}
	}
	return sig
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
	if !d.started {
		d.started = true
		d.playing = !d.manual_start
	}
	if !d.playing do return

	tracks := director_tracks(d)
	_director_ensure_built(d, tracks)

	speed := d.speed if d.speed > 0 else 1
	d.prev_time = d.time
	d.time += dt * speed

	wrapped := false
	dur := director_duration(d, tracks)
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
	_director_evaluate(d, tracks, wrapped, .Play)
}

// Jump to a time and evaluate — the scrub path (mode .Scrub). Stateful
// tracks reset and replay instead of firing crossings.
director_set_time :: proc(d: ^PlayableDirector, time: f32) {
	director_evaluate_at(d, time, .Scrub)
}

// The editor preview's PLAY advance: evaluation keeps scrub semantics (the
// world stays a pure function of time — particles replay, poses restore per
// frame) but crossings are real (mode .Preview_Play), so audio plays live
// like Unity's Timeline preview. `time` moving backwards is read as the
// preview loop wrapping — jumps use director_set_time.
director_preview_step :: proc(d: ^PlayableDirector, time: f32) {
	tracks := director_tracks(d)
	_director_ensure_built(d, tracks)
	d.prev_time = d.time
	d.time = time
	wrapped := time < d.prev_time
	_director_evaluate(d, tracks, wrapped, .Preview_Play)
}

// Evaluate at an explicit time with an explicit mode — the control track
// forwards its clip-local time through this, inheriting the parent's mode.
director_evaluate_at :: proc(d: ^PlayableDirector, time: f32, mode: Track_Mode) {
	tracks := director_tracks(d)
	_director_ensure_built(d, tracks)
	d.prev_time = mode == .Scrub ? time : d.time
	d.time = time
	wrapped := mode != .Scrub && time < d.prev_time
	_director_evaluate(d, tracks, wrapped, mode)
}

// Quiet every track the director drives — the editor calls it when its
// preview stops (each kind knows what "quiet" means for its target).
// `playing` marks the PER-FRAME restore of an auto-advancing preview:
// world-state restores (poses, activation) still run, but tracks whose
// preview effect must persist across frames (an audio voice) skip quieting
// until the preview truly stops.
director_preview_end :: proc(d: ^PlayableDirector, playing := false) {
	tracks := director_tracks(d)
	for &tv, ti in tracks {
		desc, has := track_desc(tv.kind)
		if !has || desc.preview_end == nil do continue
		ctx := _director_ctx(d, tracks, &tv, i32(ti), playing ? Track_Mode.Preview_Play : .Scrub)
		desc.preview_end(&ctx)
	}
}

// Free every track's state; the next tick rebuilds. Structural timeline
// edits (via the fingerprint) and component cleanup both land here.
director_teardown :: proc(d: ^PlayableDirector) {
	for state, ti in d.track_states {
		if state == nil do continue
		if ti >= len(d.track_state_kinds) do continue
		if desc, has := track_desc(d.track_state_kinds[ti]); has && desc.destroy != nil {
			desc.destroy(state)
		}
	}
	delete(d.track_states)
	d.track_states = nil
	for k in d.track_state_kinds do delete(k)
	delete(d.track_state_kinds)
	d.track_state_kinds = nil
	d.built = false
}

@(private = "file")
_director_ensure_built :: proc(d: ^PlayableDirector, tracks: []Timeline_Track) {
	sig := _director_tree_sig(tracks)
	if d.built && sig == d.tree_sig do return
	if d.built do director_teardown(d)
	d.built = true
	d.tree_sig = sig
	d.track_states = make([dynamic]rawptr, len(tracks))
	d.track_state_kinds = make([dynamic]string, 0, len(tracks))
	for &tv, ti in tracks {
		append(&d.track_state_kinds, _clone_default(tv.kind))
		desc, has := track_desc(tv.kind)
		if !has || desc.build == nil do continue
		ctx := _director_ctx(d, tracks, &tv, i32(ti), .Play)
		d.track_states[ti] = desc.build(&ctx)
	}
}

// Track-state bookkeeping outlives the frame — never the temp allocator.
@(private = "file")
_clone_default :: proc(s: string) -> string {
	buf := make([]u8, len(s))
	copy(buf, s)
	return string(buf)
}

@(private = "file")
_director_ctx :: proc(
	d: ^PlayableDirector,
	tracks: []Timeline_Track,
	tv: ^Timeline_Track,
	ti: i32,
	mode: Track_Mode,
	wrapped := false,
) -> Track_Ctx {
	state: rawptr
	if int(ti) < len(d.track_states) do state = d.track_states[ti]
	return Track_Ctx{
		track     = tv,
		target    = tv.target,
		owner     = engine.Transform_Handle(d.owner),
		state     = state,
		prev_time = d.prev_time,
		time      = d.time,
		wrapped   = wrapped,
		duration  = director_duration(d, tracks),
		mode      = mode,
	}
}

@(private = "file")
_director_evaluate :: proc(d: ^PlayableDirector, tracks: []Timeline_Track, wrapped: bool, mode: Track_Mode) {
	for &tv, ti in tracks {
		if tv.muted do continue
		desc, has := track_desc(tv.kind)
		if !has || desc.tick == nil do continue
		ctx := _director_ctx(d, tracks, &tv, i32(ti), mode, wrapped)
		desc.tick(&ctx)
	}
}
