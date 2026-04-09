package tests

import "../engine"
import "../app"

import "core:testing"
import "core:os"
import "core:encoding/json"

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
	engine.sm_scene_set_active(tc.scene)
	engine.scene_ensure_root(tc.scene)
}

@(private)
teardown :: proc(tc: ^TestCtx) {
	engine.scene_destroy(tc.scene)
	engine.sm_scene_set_active(nil)
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

@(test)
test_instantiate_twice_no_local_id_collision :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	childH := engine.transform_new("Child", parentH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	if sr == nil do return
	sr.color = {1, 0, 0, 1}
	sr.enabled = true

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	testing.expect(t, len(data) > 0, "scene_copy_subtree should produce data")
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	inst1 := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst1 != {}, "first instantiate should succeed")

	inst2 := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst2 != {}, "second instantiate should succeed")

	if inst1 == {} || inst2 == {} do return

	ids: map[engine.Local_ID]bool
	defer delete(ids)
	collision := false

	_collect_local_ids :: proc(w: ^engine.World, tH: engine.Transform_Handle, ids: ^map[engine.Local_ID]bool, collision: ^bool) {
		tr := engine.pool_get(&w.transforms, engine.Handle(tH))
		if tr == nil do return
		if tr.local_id in ids^ {
			collision^ = true
		}
		ids^[tr.local_id] = true
		for &c in tr.components {
			if c.local_id in ids^ {
				collision^ = true
			}
			ids^[c.local_id] = true
		}
		for child in tr.children {
			_collect_local_ids(w, engine.Transform_Handle(child.handle), ids, collision)
		}
	}

	_collect_local_ids(&tc_mem.world, inst1, &ids, &collision)
	_collect_local_ids(&tc_mem.world, inst2, &ids, &collision)

	testing.expect(t, !collision, "instantiating same subtree twice should not produce local_id collisions")
}

@(test)
test_instantiate_preserves_internal_cross_refs :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	c1H := engine.transform_new("Child1", parentH)
	c2H := engine.transform_new("Child2", parentH)
	_, sr := engine.transform_get_or_add_comp(c1H, engine.SpriteRenderer)
	if sr == nil do return
	sr.enabled = true

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	testing.expect(t, len(data) > 0, "copy should succeed")
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	inst := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst != {}, "paste should succeed")
	if inst == {} do return

	inst_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst))
	testing.expect(t, inst_t != nil, "instantiated root should exist")
	if inst_t == nil do return
	testing.expect_value(t, inst_t.name, "Parent")
	testing.expect_value(t, len(inst_t.children), 2)

	if len(inst_t.children) < 2 do return

	child1_h := inst_t.children[0].handle
	child2_h := inst_t.children[1].handle
	child1 := engine.pool_get(&tc_mem.world.transforms, child1_h)
	child2 := engine.pool_get(&tc_mem.world.transforms, child2_h)
	testing.expect(t, child1 != nil, "child1 should exist")
	testing.expect(t, child2 != nil, "child2 should exist")
	if child1 == nil || child2 == nil do return

	testing.expect_value(t, child1.name, "Child1")
	testing.expect_value(t, child2.name, "Child2")
	testing.expect_value(t, child1.parent.handle, engine.Handle(inst))
	testing.expect_value(t, child2.parent.handle, engine.Handle(inst))

	_, inst_sr := engine.transform_get_comp(engine.Transform_Handle(child1_h), engine.SpriteRenderer)
	testing.expect(t, inst_sr != nil, "instantiated SpriteRenderer should exist")
	if inst_sr == nil do return
	testing.expect_value(t, inst_sr.enabled, true)
	testing.expect(t, inst_sr.owner == engine.Transform_Handle(child1_h), "SpriteRenderer owner should point to instantiated child")
}

@(test)
test_scene_file_remap_produces_unique_ids :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("A")
	childH := engine.transform_new("B", parentH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	if sr == nil do return

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	if len(data) == 0 do return

	sf: engine.SceneFile
	if err := json.unmarshal(data, &sf); err != nil do return
	defer engine.scene_file_destroy(&sf)

	original_root := sf.root
	original_ids: [dynamic]engine.Local_ID
	defer delete(original_ids)
	for &tr in sf.transforms {
		append(&original_ids, tr.local_id)
	}

	engine._scene_file_remap_local_ids(&sf, tc_mem.scene)

	testing.expect(t, sf.root != original_root, "root local_id should be remapped")

	for tr, i in sf.transforms {
		testing.expect(t, tr.local_id != original_ids[i], "transform local_id should change after remap")
	}

	seen: map[engine.Local_ID]bool
	defer delete(seen)
	unique := true
	for tr in sf.transforms {
		if tr.local_id in seen { unique = false }
		seen[tr.local_id] = true
	}
	for c in sf.sprite_renderers {
		if c.local_id in seen { unique = false }
		seen[c.local_id] = true
	}
	testing.expect(t, unique, "all remapped ids should be unique")
}
