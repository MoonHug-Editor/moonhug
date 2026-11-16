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
