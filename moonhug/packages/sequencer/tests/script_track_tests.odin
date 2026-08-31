package sequencer_tests

// The script track: a clip wraps scripts, each getting its optional
// lifecycle procs — enter on crossing into the span, tick every Play tick
// inside it, exit on leaving. Covers the contracts that matter: the
// lifecycle fires in Play and ONLY in Play, the Once-completion clamp still
// exits a clip ending at duration, a zero-duration clip fires enter+exit
// once and never ticks, and a clip's scripts survive the serialize round
// trip with variant order, payloads and a re-resolved Ref_Local intact.
//
// LogScript is the observable: calls land in log.entries, counted by
// message.

import "core:strings"
import "core:testing"
import "moonhug:engine"
import "moonhug:engine/log"
import seq "moonhug:packages/sequencer"
import scripts "moonhug:packages/sequencer/scripts"
import undo "moonhug:editor/undo"
import common "moonhug:tests/common"

@(private = "file")
_log_count :: proc(msg: string) -> int {
	n := 0
	for e in log.entries do if e.message == msg do n += 1
	return n
}

// The clip node of `track`'s first clip (the tests build one clip per track
// unless stated). Shared with the tween track tests.
_first_clip_node :: proc(w: ^engine.World, track: engine.Transform_Handle) -> engine.Transform_Handle {
	t := engine.pool_get(&w.transforms, engine.Handle(track))
	if t == nil || len(t.children) == 0 do return {}
	return engine.Transform_Handle(t.children[0].handle)
}

// A context-allocator string: component strings are owned by the clip and
// freed by destroy_LogScript with context.allocator — under the test runner
// that is the tracking allocator, so a mismatch is a loud failure here, the
// exact class the editor's debug build crashed on.
@(private = "file")
_own :: proc(s: string) -> string {
	return strings.clone(s)
}

@(test)
test_script_track_enter_tick_exit :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()
	log.clear()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	victim := engine.transform_new("Victim", root)

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 2
	defer seq.director_teardown(d)

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0.5, duration = 0.5})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	testing.expect(t, sc != nil, "the window's clip shape carries a ScriptClip")
	if sc == nil do return

	vt := engine.pool_get(&tc.world.transforms, engine.Handle(victim))
	target := engine.Ref_Local{local_id = vt.local_id, handle = engine.Handle(victim)}
	// The span deactivates the victim: enter sets false, exit sets it back.
	append(&sc.scripts, seq.ScriptUnion(scripts.SetActiveScript{target = target, active = false}))
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{
		enter = _own("enter"), tick = _own("tick"), exit = _own("exit"),
	}))

	// Before the span: nothing fires.
	for _ in 0 ..< 4 do seq.director_tick(d, 0.1) // t = 0.4
	testing.expect(t, vt.is_active, "no script call before the span")
	testing.expect_value(t, _log_count("enter"), 0)
	testing.expect_value(t, _log_count("tick"), 0)

	// Crossing the start: enter once; tick runs the same tick.
	for _ in 0 ..< 2 do seq.director_tick(d, 0.1) // t = 0.6
	testing.expect(t, !vt.is_active, "enter must run on crossing the start")
	testing.expect_value(t, _log_count("enter"), 1)
	testing.expect(t, _log_count("tick") >= 1, "tick runs inside the span")

	// Inside the span: enter does not re-fire, tick keeps running.
	tick_before := _log_count("tick")
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 0.9
	testing.expect_value(t, _log_count("enter"), 1)
	testing.expect_value(t, _log_count("tick"), tick_before + 3)

	// Crossing the end: exit once; tick stops.
	for _ in 0 ..< 2 do seq.director_tick(d, 0.1) // t = 1.1
	testing.expect(t, vt.is_active, "exit must run on crossing the end")
	testing.expect_value(t, _log_count("exit"), 1)
	tick_at_exit := _log_count("tick")
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 1.4
	testing.expect_value(t, _log_count("tick"), tick_at_exit)
}

// A clip ending exactly at the timeline's duration: Once playback completes
// CLAMPED at duration, which no crossing window contains — the exit must
// come from the inside->outside edge on the final tick.
@(test)
test_script_exit_fires_at_once_completion :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()
	log.clear()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 1
	defer seq.director_teardown(d)

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0.5, duration = 0.5})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	if sc == nil do return
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{exit = _own("done")}))

	for _ in 0 ..< 20 do seq.director_tick(d, 0.1) // clamps at 1.0 and stops
	testing.expect_value(t, _log_count("done"), 1)
}

// A zero-duration clip is an INSTANT: its span has no inside, so enter and
// exit fire together on the tick that passes over it — once — and tick
// never runs.
@(test)
test_script_zero_duration_clip_fires_once :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()
	log.clear()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 1
	defer seq.director_teardown(d)

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0.75, duration = 0})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	if sc == nil do return
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{
		enter = _own("in"), tick = _own("during"), exit = _own("out"),
	}))

	for _ in 0 ..< 20 do seq.director_tick(d, 0.1)
	testing.expect_value(t, _log_count("in"), 1)
	testing.expect_value(t, _log_count("during"), 0)
	testing.expect_value(t, _log_count("out"), 1)
}

// Scrub and preview must never perform side effects — posing a timeline is
// not playing it.
@(test)
test_script_silent_outside_play :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()
	log.clear()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	victim := engine.transform_new("Victim", root)
	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.duration = 2
	defer seq.director_teardown(d)

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0.5, duration = 0.5})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	if sc == nil do return
	vt := engine.pool_get(&tc.world.transforms, engine.Handle(victim))
	target := engine.Ref_Local{local_id = vt.local_id, handle = engine.Handle(victim)}
	append(&sc.scripts, seq.ScriptUnion(scripts.SetActiveScript{target = target, active = false}))
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{tick = _own("no")}))

	// Scrub through and past the span, then preview-step across it.
	seq.director_set_time(d, 0.7)
	seq.director_set_time(d, 1.4)
	seq.director_preview_step(d, 0.7)
	testing.expect(t, vt.is_active, "scrub/preview must not run scripts")
	testing.expect_value(t, _log_count("no"), 0)
}

// The whole point of guid-keyed union persistence: a clip's scripts survive
// serialize -> reload with variant order, payload fields and a re-resolved
// Ref_Local handle intact (the Simulate round trip).
@(test)
test_script_clip_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	victim := engine.transform_new("Victim", root)
	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0.25, duration = 1})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	if sc == nil do return
	vt := engine.pool_get(&tc.world.transforms, engine.Handle(victim))
	want_lid := vt.local_id
	append(&sc.scripts, seq.ScriptUnion(scripts.SetActiveScript{
		target = {local_id = want_lid, handle = engine.Handle(victim)},
		active = true,
	}))
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{
		enter = _own("boom"), tick = _own("beat"), exit = _own("bye"),
	}))

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "snapshot should capture")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "restore should load")
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
	testing.expect_value(t, len(tracks[0].clips), 1)
	_, sc2 := seq.get_comp(tracks[0].clips[0].node, seq.ScriptClip)
	testing.expect(t, sc2 != nil, "the clip's kind component survives")
	if sc2 == nil do return

	testing.expect_value(t, len(sc2.scripts), 2)
	if len(sc2.scripts) != 2 do return

	sa, sa_ok := sc2.scripts[0].(scripts.SetActiveScript)
	testing.expect(t, sa_ok, "variant order survives: SetActiveScript first")
	if sa_ok {
		testing.expect_value(t, sa.target.local_id, want_lid)
		testing.expect(t, sa.active)
		testing.expect(t, engine.world_pool_valid(&tc.world, sa.target.handle),
			"the Ref_Local inside the union must re-resolve after restore")
	}
	lg, lg_ok := sc2.scripts[1].(scripts.LogScript)
	testing.expect(t, lg_ok, "variant order survives: LogScript second")
	if lg_ok {
		testing.expect_value(t, lg.enter, "boom")
		testing.expect_value(t, lg.tick, "beat")
		testing.expect_value(t, lg.exit, "bye")
	}
}

// The crash class from the editor's debug build: undo applying a value
// record over a ScriptClip frees the clip's CURRENT strings
// (_cleanup_before_unmarshal -> cleanup_ScriptClip) and unmarshals the
// payload's replacements (union_unmarshal). Every allocation and free in
// that chain must use context.allocator — under the test runner that is the
// tracking allocator, so a path reverting to a forced default allocator
// panics here instead of in the editor.
@(test)
test_script_clip_undo_apply_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	track := _mk_track(root, .ScriptTrack, seq.Timeline_Clip{start = 0, duration = 1})
	clip := _first_clip_node(&tc.world, track)
	_, sc := seq.get_comp(clip, seq.ScriptClip)
	if sc == nil do return
	append(&sc.scripts, seq.ScriptUnion(scripts.LogScript{enter = _own("before")}))

	// The undo record's before-image, as push_value stores it.
	old_bytes := undo.capture_json(sc, typeid_of(seq.ScriptClip))
	testing.expect(t, old_bytes != nil, "capture should marshal the clip")
	if old_bytes == nil do return
	defer delete(old_bytes)

	// The inspector's edit: free the old string, clone the replacement —
	// exactly what draw_string_property does.
	if lg, ok := &sc.scripts[0].(scripts.LogScript); ok {
		delete(lg.enter)
		lg.enter = _own("after")
	}

	// Undo: apply the before-image over the live component. This is the call
	// the editor crashed in.
	testing.expect(t, undo.write_json_value(sc, typeid_of(seq.ScriptClip), old_bytes, tc.scene),
		"undo apply must succeed")
	lg2, ok2 := sc.scripts[0].(scripts.LogScript)
	testing.expect(t, ok2, "variant survives the apply")
	if ok2 do testing.expect_value(t, lg2.enter, "before")
}
