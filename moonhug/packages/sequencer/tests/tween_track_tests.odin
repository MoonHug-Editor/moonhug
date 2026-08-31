package sequencer_tests

// The tween track: clip spans driving evaluate(t) — pose as a pure function
// of the playhead. Covers the contracts that matter: exact evaluation under
// Play AND scrubbing (edit mode is a first-class citizen here, unlike the
// script track), scrubbing back before the span restores the captured start
// pose, preview_end hands back the authored pose and clears the capture, a
// loop replays the same motion, and a clip's tweens survive the serialize
// round trip with runtime capture state excluded.

import "core:testing"
import "moonhug:engine"
import seq "moonhug:packages/sequencer"
import tweens "moonhug:packages/sequencer/tweens"
import common "moonhug:tests/common"

@(private = "file")
_close :: proc(a, b: [3]f32) -> bool {
	d := a - b
	return abs(d.x) < 0.001 && abs(d.y) < 0.001 && abs(d.z) < 0.001
}

// Stage with a director and one tween track: one clip [0.5, 1.5) moving the
// victim to {10, 0, 0} from wherever it started ({1, 2, 3}).
@(private = "file")
_tween_stage :: proc(tc: ^common.TestCtx, wrap: seq.Timeline_Wrap) -> (d: ^seq.PlayableDirector, victim: ^engine.Transform, clip_tweens: ^[dynamic]seq.TweenUnion) {
	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	vH := engine.transform_new("Victim", root)
	victim = engine.pool_get(&tc.world.transforms, engine.Handle(vH))
	victim.position = {1, 2, 3}

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d = cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = wrap
	d.duration = 2

	track := _mk_track(root, .TrackTween, seq.Clip_View{start = 0.5, duration = 1})
	if _, tt := seq.get_comp(track, seq.TrackTween); tt != nil {
		tt.target = {local_id = victim.local_id, handle = engine.Handle(vH)}
	}
	clip := _first_clip_node(&tc.world, track)
	_, tclip := seq.get_comp(clip, seq.ClipTween)
	if tclip == nil do return
	append(&tclip.tweens, seq.TweenUnion(tweens.TweenMoveLocalTo{to = {10, 0, 0}}))
	clip_tweens = &tclip.tweens
	return
}

@(test)
test_tween_track_play_evaluates_span :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, _ := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)

	// Before the span: the game owns the pose, nothing moves.
	for _ in 0 ..< 4 do seq.director_tick(d, 0.1) // t = 0.4
	testing.expect(t, _close(victim.position, {1, 2, 3}), "untouched before the span")

	// Mid-span: exact lerp from the captured start.
	for _ in 0 ..< 6 do seq.director_tick(d, 0.1) // t = 1.0, clip-local 0.5
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}), "midpoint pose at clip-local 0.5")

	// Past the span: landed exactly on `to`, once, and stays put.
	for _ in 0 ..< 8 do seq.director_tick(d, 0.1) // t = 1.8
	testing.expect(t, _close(victim.position, {10, 0, 0}), "exit lands on the end pose")
	victim.position = {7, 7, 7} // game code moves it after the span
	for _ in 0 ..< 2 do seq.director_tick(d, 0.1)
	testing.expect(t, _close(victim.position, {7, 7, 7}), "Play never touches the target outside the span")
}

// Scrubbing is edit mode's contract: exact pose at any playhead, and
// scrubbing back BEFORE the span restores the captured start pose.
@(test)
test_tween_track_scrub_exact_and_restores :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, _ := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)

	seq.director_set_time(d, 1.0) // clip-local 0.5
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}), "scrub pose is exact")
	seq.director_set_time(d, 1.25) // clip-local 0.75
	testing.expect(t, _close(victim.position, {7.75, 0.5, 0.75}), "scrub forward is exact")
	seq.director_set_time(d, 0.75) // clip-local 0.25 — backward, no replay needed
	testing.expect(t, _close(victim.position, {3.25, 1.5, 2.25}), "scrub backward is exact")
	seq.director_set_time(d, 0.1) // before the span: t = 0, the captured pose
	testing.expect(t, _close(victim.position, {1, 2, 3}), "before the span the timeline shows the start pose")
	seq.director_set_time(d, 1.9) // after: t = 1
	testing.expect(t, _close(victim.position, {10, 0, 0}), "after the span the timeline shows the end pose")
}

// preview_end hands the world back: authored pose restored, capture cleared
// so the next preview captures fresh.
@(test)
test_tween_track_preview_end_restores :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, clip_tweens := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)

	seq.director_set_time(d, 1.0)
	testing.expect(t, !_close(victim.position, {1, 2, 3}), "preview posed the target")
	seq.director_preview_end(d)
	testing.expect(t, _close(victim.position, {1, 2, 3}), "preview end restores the authored pose")
	if base := seq.tween_base(&clip_tweens[0]); base != nil {
		testing.expect(t, !base.captured, "preview end clears the capture")
	}

	// The next preview captures the CURRENT authored pose, not the stale one.
	victim.position = {4, 4, 4}
	seq.director_set_time(d, 1.5) // clip end: t = 1
	seq.director_set_time(d, 0.1) // back before the span
	testing.expect(t, _close(victim.position, {4, 4, 4}), "a fresh capture restores the new pose")
	seq.director_preview_end(d)
	testing.expect(t, _close(victim.position, {4, 4, 4}))
}

// A looping timeline replays the same motion: the capture survives the wrap,
// so the second pass lerps from the ORIGINAL start, not from the end pose.
@(test)
test_tween_track_loop_replays_same_motion :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, _ := _tween_stage(tc, .Loop)
	defer seq.director_teardown(d)

	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.0, mid-span
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}))
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1) // wrapped, t = 1.0 again
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}), "second pass replays from the original start")
}

// The stateless pair: explicit from/to needs no capture and poses correctly
// wherever the playhead jumps from.
@(test)
test_tween_from_to_is_stateless :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, clip_tweens := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)
	clear(clip_tweens)
	append(clip_tweens, seq.TweenUnion(tweens.TweenMoveLocalFromTo{from = {0, 0, 0}, to = {8, 0, 0}}))

	seq.director_set_time(d, 1.9) // straight past the span
	testing.expect(t, _close(victim.position, {8, 0, 0}))
	seq.director_set_time(d, 1.0) // back to the middle
	testing.expect(t, _close(victim.position, {4, 0, 0}))
	testing.expect(t, _close(victim.position, {4, 0, 0}))
}

// Round trip: `to` and the target survive; runtime capture state (`from`,
// `captured`) is json:"-" and must arrive reset.
@(test)
test_tween_clip_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, clip_tweens := _tween_stage(tc, .Once)
	// Pose mid-span so `from`/`captured` are LIVE at serialize time.
	seq.director_set_time(d, 1.0)
	if base := seq.tween_base(&clip_tweens[0]); base != nil {
		testing.expect(t, base.captured, "capture is live before the snapshot")
	}
	want_lid := victim.local_id

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc.scene = reloaded

	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil)
	if d2 == nil do return
	tracks := seq.director_tracks(d2)
	testing.expect_value(t, len(tracks), 1)
	if len(tracks) != 1 do return
	_, tt2 := seq.get_comp(tracks[0].node, seq.TrackTween)
	testing.expect(t, tt2 != nil)
	if tt2 != nil {
		testing.expect_value(t, tt2.target.local_id, want_lid)
		testing.expect(t, engine.world_pool_valid(&tc.world, tt2.target.handle),
			"the track target must re-resolve after restore")
	}
	_, tc2 := seq.get_comp(tracks[0].clips[0].node, seq.ClipTween)
	testing.expect(t, tc2 != nil)
	if tc2 == nil do return
	testing.expect_value(t, len(tc2.tweens), 1)
	if len(tc2.tweens) != 1 do return
	mv, mv_ok := tc2.tweens[0].(tweens.TweenMoveLocalTo)
	testing.expect(t, mv_ok, "variant survives")
	if mv_ok {
		testing.expect(t, _close(mv.to, {10, 0, 0}), "authored fields survive")
		testing.expect(t, !mv.captured, "runtime capture state must NOT persist")
		testing.expect(t, _close(mv.from, {0, 0, 0}), "runtime from must NOT persist")
	}
}

// A timeline PLAYED AGAIN is a new performance: .Play (the default) captures
// the game state it finds, so the second play lerps from where the game left
// the object instead of teleporting to the stale first-play pose.
@(test)
test_tween_capture_play_recaptures_between_plays :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, _ := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)

	for _ in 0 ..< 25 do seq.director_tick(d, 0.1) // completes at duration
	testing.expect(t, _close(victim.position, {10, 0, 0}), "first play lands on `to`")

	// The game moves the object between performances.
	seq.director_stop(d)
	victim.position = {20, 0, 0}
	seq.director_play(d)
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.0, clip-local 0.5
	testing.expect(t, _close(victim.position, {15, 0, 0}),
		"second play lerps from the CURRENT pose, not the stale capture")
}

// .Enter refreshes on every span entry: with an absolute `to`, the second
// loop pass starts from the end pose, so the object holds at `to` instead of
// snapping back — the continuing-motion policy.
@(test)
test_tween_capture_enter_recaptures_each_pass :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, clip_tweens := _tween_stage(tc, .Loop)
	defer seq.director_teardown(d)
	if base := seq.tween_base(&clip_tweens[0]); base != nil do base.capture = .Enter

	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.0, first pass mid
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}), "first pass lerps from the start pose")
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1) // wrapped, second pass mid
	testing.expect(t, _close(victim.position, {10, 0, 0}),
		"second pass re-captured at entry: from == to, the object holds")
}

// Edit mode ignores capture policy: an .Enter tween scrubs exactly like a
// .Play one — the preview always shows the first pass.
@(test)
test_tween_capture_enter_scrubs_stable :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	d, victim, clip_tweens := _tween_stage(tc, .Once)
	defer seq.director_teardown(d)
	if base := seq.tween_base(&clip_tweens[0]); base != nil do base.capture = .Enter

	seq.director_set_time(d, 1.9) // past the span: captures, lands on `to`
	testing.expect(t, _close(victim.position, {10, 0, 0}))
	seq.director_set_time(d, 1.0) // back into the middle: SAME capture
	testing.expect(t, _close(victim.position, {5.5, 1, 1.5}),
		"scrubbing back into the span keeps the first capture")
	seq.director_set_time(d, 0.1)
	testing.expect(t, _close(victim.position, {1, 2, 3}), "before the span restores the start pose")
}
