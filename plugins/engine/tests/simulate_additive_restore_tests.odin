package engine_tests

// Stop gives every loaded scene its content of Start back, not only the
// simulated one: what the run moved or spawned in a second loaded scene is
// undone. A loaded scene the run left alone is not rebuilt.

import "core:os"
import "core:testing"
import "moonhug:editor/simulate"
import "moonhug:packages/engine"

@(private = "file")
_sim_hosts := [1]simulate.Host{{name = "additive_restore_test", tick = proc(dt: f32, step: bool) {}}}

// The transform named `name` in scene `s`, nil for none.
@(private = "file")
_in_scene :: proc(s: ^engine.Scene, name: string) -> ^engine.Transform {
	it := engine.pool_iterator(&engine.ctx_world().transforms)
	for tr, _ in engine.pool_next(&it) do if tr.scene == s && tr.name == name do return tr
	return nil
}

@(test)
test_stop_restores_every_loaded_scene :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	simulate.install({}, _sim_hosts[:])
	defer simulate.install({}, nil)
	defer simulate.stop()

	changed_path := "moonhug/tests/fixtures/_test_sim_restore_changed.scene"
	still_path := "moonhug/tests/fixtures/_test_sim_restore_still.scene"
	testing.expect(t, fixture_write_empty_scene(changed_path, "ChangedRoot") && fixture_write_empty_scene(still_path, "StillRoot"), "wrote the fixtures")
	defer os.remove(changed_path)
	defer os.remove(still_path)
	changed := engine.scene_load(changed_path, additive = true)
	still := engine.scene_load(still_path, additive = true)
	testing.expect(t, changed != nil && still != nil, "two more scenes are loaded")
	if changed == nil || still == nil do return
	changed_id := changed.session_id

	// An edit made before Play and not saved: Stop keeps it.
	crate := engine.transform_new("Crate", engine.Transform_Handle(changed.root.handle))
	engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position = {1, 0, 0}

	testing.expect(t, simulate.start(), "Play starts")
	engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position = {9, 9, 9}
	engine.transform_new("Spawned", engine.Transform_Handle(changed.root.handle))
	simulate.stop()

	back := engine.sm_scene_find_by_session_id(changed_id)
	testing.expect(t, back != nil, "the changed scene is still loaded, the same scene to the editor")
	if back == nil do return
	restored := _in_scene(back, "Crate")
	testing.expect(t, restored != nil && restored.position == [3]f32{1, 0, 0}, "the object is back where it was at Start")
	testing.expect(t, _in_scene(back, "Spawned") == nil, "what the run spawned is gone")
	testing.expect(t, engine.sm_scene_is_loaded(still) && _in_scene(still, "StillRoot") != nil, "a scene the run left alone is not rebuilt")
}
