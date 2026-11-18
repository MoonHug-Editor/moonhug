package engine_tests

// The scene manager's slots are reused: registering and unloading more
// scenes than there are slots keeps working.

import "core:testing"
import "moonhug:packages/engine"

@(test)
test_scene_manager_reuses_freed_slots :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	for _ in 0 ..< engine.MAX_SCENES + 20 {
		s := engine.scene_new()
		engine.sm_scene_set_active(s)
		testing.expect(t, engine.sm_scene_get_active() == s, "a scene made active is registered and active")
		engine.sm_scene_unload(s)
	}
	last := engine.scene_new()
	engine.sm_scene_set_active(last)
	testing.expect(t, engine.sm_scene_is_loaded(last) && engine.sm_scene_get_active() == last, "the slots did not run out")
	engine.sm_scene_unload(last)
	engine.sm_scene_set_active(tc.scene)
}

// Unloading the active scene makes another loaded scene the active one.
@(test)
test_unloading_the_active_scene_activates_another :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	second := engine.scene_new()
	engine.sm_scene_set_active(second)
	testing.expect(t, engine.sm_scene_get_active() == second, "the new scene is active")
	engine.sm_scene_unload(second)
	testing.expect(t, engine.sm_scene_get_active() == tc.scene, "the scene still loaded is active")

	// Unloading a scene that is not the active one changes nothing.
	third := engine.scene_new()
	engine.sm_scene_set_active(third)
	engine.sm_scene_set_active(tc.scene)
	engine.sm_scene_unload(third)
	testing.expect(t, engine.sm_scene_get_active() == tc.scene, "the active scene stays")
}
