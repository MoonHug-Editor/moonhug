package tests_common

// Shared test-world bootstrap: registrations, world init, active scene,
// teardown. Lives in its own package so per-package test suites
// (moonhug/packages/<name>/tests — docs/core/Plugins.md) can import it alongside
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

import "base:runtime"
import "core:os"
import "core:strings"
import "../../engine"
import "moonhug:engine_editor/asset_pipeline"
import "../../engine/registration"

TestCtx :: struct {
	world: engine.World,
	uc:    engine.UserContext,
	scene: ^engine.Scene,
	path:  string,
}

@(private)
_serializers_registered: bool

// The one-time registrations run at program start, before any test body. Many
// tests call engine.asset_db_init BEFORE setup, and that scan needs the
// importers: registering in setup made them pass only after an earlier test
// had called setup, and fail when run alone. Registries live for the whole run,
// so they get the default allocator (a test's tracking allocator dies with it).
@(init)
_register_at_start :: proc "contextless" () {
	context = runtime.default_context()
	registration.register_type_guids()
	_register_once()
}

@(private)
_register_once :: proc() {
	if _serializers_registered do return
	// EVERY installed package registers (registration is the same
	// all-packages generated bundle the editor uses), so tests never
	// depend on a specific runnable package being installed.
	registration.register_packages()
	registration.phase_run(.SerializationInit)
	registration.phase_run(.ImportersInit)
	// The import stack is editor-side (mode=Editor phases, absent from
	// the dispatcher above) — tests import like the editor does.
	// Package importers register from the package's OWN tests (this
	// package never imports moonhug:packages).
	asset_pipeline.register_builtin_importers()
	asset_pipeline.import_pipeline_install()
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

setup :: proc(tc: ^TestCtx, path: string = "") {
	registration.register_type_guids()
	_register_once() // done at start (_register_at_start), a no-op here
	engine.w_init(&tc.world)
	tc.uc.world = &tc.world
	// Tests exercise editor behaviour: nested-prefab resolve is gated on
	// application_is_editor(), and the fixtures assume it runs.
	tc.uc.is_editor = true
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
	engine.gizmo_buffer_destroy(&tc.uc.gizmos)
	if tc.path != "" do os.remove(tc.path)
}

// Deletes `dir` and everything under it (a fixture library/, a temp source
// folder).
remove_tree :: proc(dir: string) {
	handle, err := os.open(dir)
	if err != nil do return
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return
	for entry in entries {
		full := strings.concatenate({dir, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			remove_tree(full)
		} else {
			os.remove(full)
		}
	}
	os.remove(dir)
}
