package tests

import "../engine"
import "../app"

import "core:testing"
import "core:os"

@(private)
TestCtx :: struct {
	world: engine.World,
	uc:    engine.UserContext,
	scene: ^engine.Scene,
	path:  string,
}

@(private)
setup :: proc(tc: ^TestCtx, path: string = "") {
	app.register_type_guids()
	engine.w_init(&tc.world)
	tc.uc.world = &tc.world
	tc.path = path
	context.user_ptr = &tc.uc
	tc.scene = engine.scene_new()
	engine.scene_set_active(tc.scene)
	engine.scene_ensure_root(tc.scene)
}

@(private)
teardown :: proc(tc: ^TestCtx) {
	engine.scene_destroy(tc.scene)
	engine.scene_set_active(nil)
	if tc.path != "" do os.remove(tc.path)
}

@(test)
test_save_load_empty_scene :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_empty.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return

	testing.expect_value(t, loaded.next_local_id, tc_mem.scene.next_local_id)
	testing.expect_value(t, loaded.root.pptr.local_id, engine.Local_ID(1))

	engine.scene_destroy(loaded)
}

@(test)
test_save_load_scene_with_transform :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_transform.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Player")
	engine.scene_set_root(tc_mem.scene, tH)

	transform := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	transform.position = {1, 2, 3}
	transform.scale = {4, 5, 6}

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return

	testing.expect(t, loaded.root.pptr.local_id != 0, "root should be set")

	loaded_t := engine.pool_get(&tc_mem.world.transforms, loaded.root.handle)
	testing.expect(t, loaded_t != nil, "loaded Transform should exist in pool")
	if loaded_t == nil do return
	testing.expect_value(t, loaded_t.name, "Player")
	testing.expect_value(t, loaded_t.position, [3]f32{1, 2, 3})
	testing.expect_value(t, loaded_t.scale, [3]f32{4, 5, 6})

	engine.scene_destroy(loaded)
}

@(test)
test_save_load_scene_with_sprite_renderer :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sprite_renderer.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Player")
	engine.scene_set_root(tc_mem.scene, tH)

	_, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "SpriteRenderer should be added")
	if sr == nil do return
	sr.color = {1, 0, 0.5, 1}
	sr.enabled = true

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	defer engine.scene_destroy(loaded)

	testing.expect(t, loaded.root.pptr.local_id != 0, "root should be set")

	loaded_t := engine.pool_get(&tc_mem.world.transforms, loaded.root.handle)
	testing.expect(t, loaded_t != nil, "loaded Transform should exist in pool")
	if loaded_t == nil do return
	testing.expect_value(t, loaded_t.name, "Player")
	testing.expect_value(t, len(loaded_t.components), 1)

	_, loaded_sr := engine.transform_get_comp(engine.Transform_Handle(loaded.root.handle), engine.SpriteRenderer)
	testing.expect(t, loaded_sr != nil, "loaded SpriteRenderer should exist")
	if loaded_sr == nil do return
	testing.expect_value(t, loaded_sr.color, [4]f32{1, 0, 0.5, 1})
	testing.expect_value(t, loaded_sr.enabled, true)
	testing.expect(t, loaded_sr.owner == engine.Transform_Handle(loaded.root.handle), "SpriteRenderer owner should point to loaded transform")
}
