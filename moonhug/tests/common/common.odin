package tests_common

// Shared test-world bootstrap: registrations, world init, active scene,
// teardown. Lives in its own package so per-package test suites
// (moonhug/packages/<name>/tests — docs/Plugins.md) can import it alongside
// the central moonhug/tests suite (which re-exports the short names).
//
// Usage (the context does NOT survive the setup() call — set user_ptr in the
// test body):
//
//   tc := new(common.TestCtx)
//   defer free(tc)
//   common.setup(tc)
//   context.user_ptr = &tc.uc
//   defer common.teardown(tc)

import "core:os"
import "../../engine"
import "../../engine/serialization"
import "../../engine/registration"

TestCtx :: struct {
	world: engine.World,
	uc:    engine.UserContext,
	scene: ^engine.Scene,
	path:  string,
}

@(private)
_serializers_registered: bool

@(private)
_tween_initialized: bool

setup :: proc(tc: ^TestCtx, path: string = "") {
	registration.register_type_guids()
	if !_serializers_registered {
		// EVERY installed package registers (registration is the same
		// all-packages generated bundle the editor uses), so tests never
		// depend on a specific runnable package being installed.
		registration.register_packages()
		// User marshalers (Asset_GUID, unions) ride serialization.init —
		// scene JSON round-trips fail without them.
		serialization.init()
		// Mirror editor/main.odin: nested_scene_revert_override needs pointer
		// typeids for primitive field types (position, color, scale, …) so it
		// can hand a properly-typed `any` to json.unmarshal_any.
		engine.register_pointer_type(bool)
		engine.register_pointer_type(int)
		engine.register_pointer_type(i32)
		engine.register_pointer_type(u32)
		engine.register_pointer_type(f32)
		engine.register_pointer_type(f64)
		engine.register_pointer_type(string)
		_serializers_registered = true
	}
	if !_tween_initialized {
		engine.tween_init()
		_tween_initialized = true
	}
	engine.w_init(&tc.world)
	tc.uc.world = &tc.world
	tc.path = path
	context.user_ptr = &tc.uc
	tc.scene = engine.scene_new()
	engine.sm_scene_set_active(tc.scene)
	engine.scene_ensure_root(tc.scene)
}

teardown :: proc(tc: ^TestCtx) {
	// Destroy every scene still registered with the scene manager — NOT
	// tc.scene by pointer: scene_load_single_path destroys all loaded scenes
	// (tc.scene included), so that pointer may be stale, and the scenes the
	// test loaded afterwards live only in the manager's slots.
	engine.sm_shutdown()
	engine.sm_scene_set_active(nil)
	engine.world_destroy_all(&tc.world)
	if tc.path != "" do os.remove(tc.path)
}
