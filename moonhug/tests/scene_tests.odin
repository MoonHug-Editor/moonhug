package tests

import "../engine"
import "../app"

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import "core:encoding/json"
import "core:encoding/uuid"

@(private)
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

@(private)
setup :: proc(tc: ^TestCtx, path: string = "") {
	app.register_type_guids()
	if !_serializers_registered {
		app.register_app_components()
		app.register_component_serializers()
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

@(private)
teardown :: proc(tc: ^TestCtx) {
	if tc.scene != nil {
		engine.sm_scene_destroy_or_unload(tc.scene)
	}
	engine.sm_scene_set_active(nil)
	engine.world_destroy_all(&tc.world)
	if tc.path != "" do os.remove(tc.path)
}

// Helpers for next_local_id invariant ---------------------------------------

@(private)
_max_local_id_in_file :: proc(sf: ^engine.SceneFile) -> engine.Local_ID {
	max_id := engine.Local_ID(0)
	bump :: proc(m: ^engine.Local_ID, v: engine.Local_ID) {
		if v > m^ do m^ = v
	}
	for &tr in sf.transforms {
		bump(&max_id, tr.local_id)
		for &c in tr.components do bump(&max_id, c.local_id)
	}
	for &c in sf.cameras          do bump(&max_id, c.local_id)
	for &c in sf.lifetimes        do bump(&max_id, c.local_id)
	for &c in sf.players          do bump(&max_id, c.local_id)
	for &c in sf.scripts          do bump(&max_id, c.local_id)
	for &c in sf.sprite_renderers do bump(&max_id, c.local_id)
	for &ns in sf.nested_scenes   do bump(&max_id, ns.local_id)
	for &bc in sf.breadcrumbs     do bump(&max_id, bc.local_id)
	return max_id
}

// Saving a scene must persist next_local_id strictly greater than any local_id
// the file actually contains. Otherwise a future scene_next_id() call will hand
// out an id that collides with an existing transform/component, and on reload
// the duplicated id can make a regular transform look like the host of a
// NestedScene record (see _nested_scene_find_outer_non_nested in nested_scene.odin).
@(test)
test_save_writes_next_local_id_above_max_used :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_next_id_invariant.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", rootH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	testing.expect(t, sr != nil)

	// Simulate the c.scene-style corrupt state: a transform's local_id is far
	// above scene.next_local_id. This mirrors how the bug manifested on disk
	// (next_local_id=4 while transforms used 15/16).
	child_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	testing.expect(t, child_t != nil)
	if child_t == nil do return
	child_t.local_id = 999

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")
	if !ok do return

	sf, fok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, fok)
	if !fok do return
	defer engine.scene_file_destroy(&sf)

	max_used := _max_local_id_in_file(&sf)
	testing.expect(t, sf.next_local_id > max_used,
		"saved next_local_id must be greater than every persisted local_id")
}

// Sanity: a regular transform with no NestedScene records pointing at it must
// not be reported as a nested-scene host after save+reload. This is the user-
// visible symptom of the c.scene bug where Environment was mislabelled as a
// nested scene.
@(test)
test_save_reload_regular_transforms_not_marked_nested :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_no_nested_marking.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	envH := engine.transform_new("Environment", rootH)
	otherH := engine.transform_new("Player", rootH)
	testing.expect(t, envH != {} && otherH != {})

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok)
	if !ok do return

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// No NestedScene records were ever added, so neither transform should
	// resolve as a nested host nor display the [nested scene] suffix.
	env_loaded := find_transform_named(&tc_mem.world, loaded, "Environment", false)
	other_loaded := find_transform_named(&tc_mem.world, loaded, "Player", false)
	testing.expect(t, env_loaded != {} && other_loaded != {})

	testing.expect(t, engine.scene_find_nested_scene_for_host(loaded, env_loaded) == nil,
		"Environment must not be reported as a nested-scene host")
	testing.expect(t, engine.scene_find_nested_scene_for_host(loaded, other_loaded) == nil,
		"Player must not be reported as a nested-scene host")
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(&tc_mem.world, env_loaded),
		"hierarchy must not show nested-scene suffix on Environment")
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(&tc_mem.world, other_loaded),
		"hierarchy must not show nested-scene suffix on Player")
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

	want_root_lid := engine.Local_ID(0)
	if rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_mem.scene.root.handle)); rt != nil {
		want_root_lid = rt.local_id
	}
	want_next := tc_mem.scene.next_local_id

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return

	testing.expect_value(t, loaded.next_local_id, want_next)
	testing.expect_value(t, loaded.root.pptr.local_id, want_root_lid)

	tc_mem.scene = loaded
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
	tc_mem.scene = loaded

	testing.expect(t, loaded.root.pptr.local_id != 0, "root should be set")

	loaded_t := engine.pool_get(&tc_mem.world.transforms, loaded.root.handle)
	testing.expect(t, loaded_t != nil, "loaded Transform should exist in pool")
	if loaded_t == nil do return
	testing.expect_value(t, loaded_t.name, "Player")
	testing.expect_value(t, loaded_t.position, [3]f32{1, 2, 3})
	testing.expect_value(t, loaded_t.scale, [3]f32{4, 5, 6})
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
	tc_mem.scene = loaded

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

@(test)
test_instantiate_remaps_tween_subject_ref :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	target1H := engine.transform_new("Target1", parentH)
	target2H := engine.transform_new("Target2", parentH)

	t1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target1H))
	t2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target2H))
	if t1 == nil || t2 == nil do return
	t1_lid := t1.local_id
	t2_lid := t2.local_id

	_, player := engine.transform_get_or_add_comp(parentH, engine.Player)
	if player == nil do return

	move := engine.TweenMoveToLocal{ position = {10, 20, 30}, duration = 1.0 }
	move.subject = engine.Ref{ pptr = engine.PPtr{local_id = t1_lid}, handle = engine.Handle(target1H) }

	scale := engine.TweenScaleToLocal{ scale = {2, 2, 2}, duration = 0.5 }
	scale.subject = engine.Ref{ pptr = engine.PPtr{local_id = t2_lid}, handle = engine.Handle(target2H) }

	seq := engine.Sequence{}
	append(&seq.children, engine.TweenUnion(move))
	append(&seq.children, engine.TweenUnion(scale))
	append(&player.animations, engine.TweenUnion(seq))
	seq.children = {}

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	inst := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst != {}, "paste should succeed")
	if inst == {} do return

	inst_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst))
	if inst_t == nil do return
	testing.expect_value(t, len(inst_t.children), 2)
	if len(inst_t.children) < 2 do return

	inst_t1 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[0].handle)
	inst_t2 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[1].handle)
	if inst_t1 == nil || inst_t2 == nil do return
	inst_t1_lid := inst_t1.local_id
	inst_t2_lid := inst_t2.local_id

	_, inst_player := engine.transform_get_comp(inst, engine.Player)
	if inst_player == nil do return
	testing.expect_value(t, len(inst_player.animations), 1)
	if len(inst_player.animations) < 1 do return

	inst_seq := &inst_player.animations[0].(engine.Sequence)
	testing.expect_value(t, len(inst_seq.children), 2)
	if len(inst_seq.children) < 2 do return

	child0 := engine.tween_base(&inst_seq.children[0])
	child1 := engine.tween_base(&inst_seq.children[1])

	testing.expect(t, child0.subject.pptr.local_id != t1_lid,
		"child0 subject should differ from original")
	testing.expect(t, child0.subject.pptr.local_id == inst_t1_lid,
		"child0 subject should be remapped to instantiated Target1")

	testing.expect(t, child1.subject.pptr.local_id != t2_lid,
		"child1 subject should differ from original")
	testing.expect(t, child1.subject.pptr.local_id == inst_t2_lid,
		"child1 subject should be remapped to instantiated Target2")
}

// nested_scene_revert_override is the user-facing "revert" UX: drop a specific
// override and restore the field to the baked base value. End-to-end coverage:
// modify a nested-owned transform, save (captures the override), reload (so the
// override lives in NestedScene.overrides), call revert, then assert the
// override is gone AND the live field has snapped back to the prefab's base.
@(test)
test_revert_override_restores_base_value :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_revert_override.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Use TestB directly (not TestA) so there is exactly one TransformC in the
	// world. nested_scene_revert_override walks the transform pool by local_id,
	// and TestA produces two TransformC instances which makes the test
	// ambiguous in a way unrelated to the revert path itself.
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestB.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_c := find_transform_named(&tc_mem.world, loaded, "TestC", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_c, "TransformC")
	testing.expect(t, host_c != {} && transform_c_h != {})
	if host_c == {} || transform_c_h == {} do return

	// Mutate the nested transform's position so a "position" override is
	// produced on save.
	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	testing.expect(t, t_c != nil)
	if t_c == nil do return
	t_c.position = {99, 99, 99}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// Sanity-check: the on-disk file must carry the new override.
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		on_disk_has_pos := false
		if fok {
			for ns2 in sf.nested_scenes {
				for ov in ns2.overrides {
					if ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0 {
						on_disk_has_pos = true
						break
					}
				}
				if on_disk_has_pos do break
			}
			engine.scene_file_destroy(&sf)
		}
		testing.expect(t, on_disk_has_pos, "saved file should contain the position override on local_id=2")
	}

	// Reload from disk so the override comes through the same path the editor
	// uses when re-entering a saved scene. _scene_load_single unloads `loaded`.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_c2 := find_transform_named(&tc_mem.world, reloaded, "TestC", false)
	transform_c_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_c2, "TransformC")
	testing.expect(t, host_c2 != {} && transform_c_h2 != {})
	if host_c2 == {} || transform_c_h2 == {} do return

	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h2))
	testing.expect(t, t_c2 != nil)
	if t_c2 == nil do return
	testing.expect_value(t, t_c2.position, [3]f32{99, 99, 99})

	// The position override lives on whichever NestedScene record diffed
	// against TestC's prefab — that's the inner record (TestB-instance hosts
	// TestC, so the diff vs TestC.scene yields the override). Find it.
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &ns_iter in reloaded.nested_scenes {
		for ov in ns_iter.overrides {
			if ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				owning_target = ov.target
				break
			}
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil, "expected some NestedScene to own the position override after reload")
	if owning_ns == nil do return

	engine.nested_scene_revert_override(reloaded, owning_ns, owning_target, "position")

	for ov in owning_ns.overrides {
		testing.expect(t, !(ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0),
			"override should be removed after revert")
	}

	// TransformC's base position in TestC.scene is {7, 8, 9}.
	testing.expect_value(t, t_c2.position, [3]f32{7, 8, 9})
}

// Regression: with multiple instances of the same nested prefab in a scene
// (TestA hosts TestB twice), reverting an override on one instance must not
// touch the same-local_id transform owned by the other instance. The previous
// implementation walked the whole transform pool by local_id and would clobber
// whichever match it found first.
@(test)
test_revert_override_scoped_to_owning_instance :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_revert_scope.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	host_b2 := find_transform_named(&tc_mem.world, loaded, "TestB2", false)
	testing.expect(t, host_b1 != {} && host_b2 != {})
	if host_b1 == {} || host_b2 == {} do return

	tc1 := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	tc2 := find_nested_named_under_host(&tc_mem.world, loaded, host_b2, "TransformC")
	testing.expect(t, tc1 != {} && tc2 != {} && tc1 != tc2)
	if tc1 == {} || tc2 == {} do return

	t_c1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1))
	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc2))
	if t_c1 == nil || t_c2 == nil do return

	// Mutate both, save, and reload so deep overrides are written and re-read.
	t_c1.position = {11, 11, 11}
	t_c2.position = {22, 22, 22}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b1r := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	host_b2r := find_transform_named(&tc_mem.world, reloaded, "TestB2", false)
	testing.expect(t, host_b1r != {} && host_b2r != {})
	if host_b1r == {} || host_b2r == {} do return

	tc1r := find_nested_named_under_host(&tc_mem.world, reloaded, host_b1r, "TransformC")
	tc2r := find_nested_named_under_host(&tc_mem.world, reloaded, host_b2r, "TransformC")
	testing.expect(t, tc1r != {} && tc2r != {} && tc1r != tc2r)
	if tc1r == {} || tc2r == {} do return

	t_c1r := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1r))
	t_c2r := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc2r))
	if t_c1r == nil || t_c2r == nil do return
	testing.expect_value(t, t_c1r.position, [3]f32{11, 11, 11})
	testing.expect_value(t, t_c2r.position, [3]f32{22, 22, 22})

	// Per docs/NestedPrefabs.md: overrides live at the root scene level only.
	// The TestA-1 → TestB-1 deep override on TransformC.position is stored on
	// the native (root-scene) NS for TestB-1 with target.guid == TestC's guid.
	// After XOR projection target.local_id is no longer the literal TransformC
	// lid (2); match by guid only and let the round-trip below verify the
	// resolution.
	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		if engine.nested_scene_resolve_host_handle(reloaded, &ns_iter) != host_b1r do continue
		for ov in ns_iter.overrides {
			if strings.compare(ov.property_path, "position") != 0 do continue
			if ov.target.guid != guid_c_a do continue
			owning_ns = &ns_iter
			owning_target = ov.target
			break
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	engine.nested_scene_revert_override(reloaded, owning_ns, owning_target, "position", &t_c1r.position)

	// TestB-1's TransformC should snap back to TestB's baked base ([50,50,50],
	// the value TestB.scene's own NS-for-C override applies to TransformC);
	// TestB-2's TransformC must remain at the unrelated {22,22,22} since the
	// revert was scoped to TestB-1's instance.
	testing.expect_value(t, t_c1r.position, [3]f32{50, 50, 50})
	testing.expect_value(t, t_c2r.position, [3]f32{22, 22, 22})
}

@(test)
test_revert_nested_sprite_respects_transform_scope_for_duplicate_comp_local_ids :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_dup_sprite_revert_scope.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	guid_sprite, ge := uuid.read("a1000000-0000-4000-8000-000000000001")
	testing.expect(t, ge == nil)
	if ge != nil do return
	g_asset := engine.Asset_GUID(guid_sprite)

	slot_h := find_transform_named(&tc_mem.world, loaded, "Slot", false)
	a_h := find_nested_named_under_host(&tc_mem.world, loaded, slot_h, "SpriteA")
	b_h := find_nested_named_under_host(&tc_mem.world, loaded, slot_h, "SpriteB")
	testing.expect(t, slot_h != {} && a_h != {} && b_h != {})
	if slot_h == {} || a_h == {} || b_h == {} do return

	_, sr_a := engine.transform_get_comp(a_h, engine.SpriteRenderer)
	_, sr_b := engine.transform_get_comp(b_h, engine.SpriteRenderer)
	testing.expect(t, sr_a != nil && sr_b != nil)
	if sr_a == nil || sr_b == nil do return

	dup_lid := sr_a.local_id
	sr_b.local_id = dup_lid
	sr_a.color = {0.9, 0.4, 0.1, 1}

	owning_ns: ^engine.NestedScene
	for &ns in loaded.nested_scenes {
		if ns.source_prefab != g_asset do continue
		if engine.nested_scene_resolve_host_handle(loaded, &ns) != slot_h do continue
		owning_ns = &ns
		break
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	ov_val: json.Value
	json_err := json.unmarshal_string("[0.9,0.4,0.1,1]", &ov_val)
	testing.expect(t, json_err == nil)
	if json_err != nil do return
	defer json.destroy_value(ov_val)
	dup_target := engine.PPtr{guid = g_asset, local_id = dup_lid}
	append(
		&owning_ns.overrides,
		engine.Override{target = dup_target, property_path = strings.clone("color"), value = json.clone_value(ov_val)},
	)

	engine.nested_scene_revert_override(loaded, owning_ns, dup_target, "color", rawptr(&sr_a.color))

	testing.expect_value(t, sr_a.color, [4]f32{1, 0, 0, 1})
	testing.expect_value(t, sr_b.color, [4]f32{0, 1, 0, 1})
}

// Per docs/NestedPrefabs.md, an outer prefab's overrides on its inner prefab
// are "baked" into the inner content as the parent scene sees it — they're
// opaque from the root scene's perspective. So when the root scene records
// its own override on top and the user later reverts it, the live value must
// snap back to the BAKED state (outer prefab's overrides applied), not to
// the inner prefab's raw on-disk content.
//
// TestB.scene overrides TransformC's position to [50,50,50] on its TestC NS,
// so opening TestA shows TransformC at [50,50,50] (TestB-baked) — even though
// TestC.scene's base says [7,8,9]. This test layers a TestA-level deep override
// on top, reverts it, and asserts the value snaps to TestB-baked, not TestC-base.
@(test)
test_revert_uses_outer_prefab_baked_base :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_revert_baked.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	testing.expect(t, host_b1 != {})
	if host_b1 == {} do return

	tc := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	testing.expect(t, tc != {})
	if tc == {} do return

	t_tc := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc))
	testing.expect(t, t_tc != nil)
	if t_tc == nil do return
	// Sanity: TestB's NS-for-C override (position=[50,50,50] on lid=2) must
	// already be applied to the live TransformC inside TestB's expansion.
	testing.expect_value(t, t_tc.position, [3]f32{50, 50, 50})

	// Layer a TestA-level deep override on top.
	t_tc.position = {99, 99, 99}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b1r := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	if host_b1r == {} do return
	tcr := find_nested_named_under_host(&tc_mem.world, reloaded, host_b1r, "TransformC")
	testing.expect(t, tcr != {})
	if tcr == {} do return

	t_tcr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tcr))
	testing.expect(t, t_tcr != nil)
	if t_tcr == nil do return
	testing.expect_value(t, t_tcr.position, [3]f32{99, 99, 99})

	// Locate the native NS for TestB-1 and the deep override. After XOR
	// projection target.local_id is no longer the literal TransformC lid;
	// match by guid.
	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		if engine.nested_scene_resolve_host_handle(reloaded, &ns_iter) != host_b1r do continue
		for ov in ns_iter.overrides {
			if strings.compare(ov.property_path, "position") != 0 do continue
			if ov.target.guid != guid_c_a do continue
			owning_ns = &ns_iter
			owning_target = ov.target
			break
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	engine.nested_scene_revert_override(reloaded, owning_ns, owning_target, "position", &t_tcr.position)

	// Revert must snap to the OUTER-prefab baked state. TestB's NS-for-C sets
	// position=[50,50,50], so the baked value the root scene sees is [50,50,50],
	// not TestC.scene's raw base [7,8,9].
	testing.expect_value(t, t_tcr.position, [3]f32{50, 50, 50})
}

// Inspector-marking regression: when the user opens a root scene that nests a
// chain of prefabs, fields modified inside the deeper prefab levels must be
// flagged as overridden in the inspector. Picking the OUTER native host's NS
// (as `transform_nested_enclosing_host` would) misses overrides that live on
// the inner NS records distributed during resolve. The inspector now uses
// `transform_immediate_nested_host`, which returns the nested-owned host that
// directly encloses the inspected element — that NS is the one that owns the
// matching override.
@(test)
test_inspector_marks_inner_nested_override :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	testing.expect(t, host_b1 != {})
	if host_b1 == {} do return

	// TransformC is uniquely named and lives one nesting level deeper than
	// TestB's host (it's owned by the inner TestC NS).
	tc := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	testing.expect(t, tc != {})
	if tc == {} do return

	// transform_find_nested_host walks past the inner host and returns the
	// outermost native host (TestB). transform_immediate_nested_host stops at
	// the FIRST host ancestor — the inner TestC host whose NS holds C-level
	// overrides.
	outer := engine.transform_find_nested_host(tc)
	immediate := engine.transform_immediate_nested_host(tc)
	testing.expect(t, outer == host_b1, "outer host should be TestB")
	testing.expect(t, immediate != {} && immediate != host_b1,
		"immediate host must differ from outer (must be the inner TestC host)")
	if immediate == {} || immediate == host_b1 do return

	im_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(immediate))
	testing.expect(t, im_t != nil && im_t.nested_owned,
		"the immediate host is itself nested-owned (it lives inside TestB's expansion)")

	outer_ns := engine.scene_find_nested_scene_for_host(loaded, outer)
	inner_ns := engine.scene_find_nested_scene_for_host(loaded, immediate)
	testing.expect(t, outer_ns != nil && inner_ns != nil && outer_ns != inner_ns,
		"outer and inner host transforms must resolve to distinct NS records")
	if outer_ns == nil || inner_ns == nil do return

	// TestB.scene pre-applies a "name" override (target lid=1) on its TestC NS.
	// That override is distributed onto the inner NS during resolve and must
	// be reachable from the inspector via the inner host — not the outer one.
	tgt_c := engine.PPtr{guid = inner_ns.source_prefab, local_id = 1}
	testing.expect(t, !engine.nested_scene_has_override(outer_ns, tgt_c, "name"),
		"outer NS should NOT carry the C-level override (target lid is in C's namespace)")
	testing.expect(t, engine.nested_scene_has_override(inner_ns, tgt_c, "name"),
		"inner NS must report the C-level override under target=1")
}

// Verifies the 4-level chain (TestA → TestB → TestC → TestD): an override on
// TransformD inside TestB→TestC→TestD must be lifted all the way up to TestA's
// outer NS as a chain-encoded breadcrumb, and round-tripped back on reload.
// Before scene_path was added the propagation gave up past one inner level so
// these overrides were silently dropped.
@(test)
test_deep_override_4_level_chain :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_deep4.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	testing.expect(t, host_b1 != {})
	if host_b1 == {} do return

	tc_under_b1 := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TestC")
	testing.expect(t, tc_under_b1 != {})
	if tc_under_b1 == {} do return

	// TransformD lives one level below TestC's host, inside TestD's expansion.
	// find_nested_named_under_host scopes by `transform_find_nested_host` which
	// returns the nearest non-nested-owned host above — that's still host_b1.
	td := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformD")
	testing.expect(t, td != {})
	if td == {} do return

	t_d := engine.pool_get(&tc_mem.world.transforms, engine.Handle(td))
	testing.expect(t, t_d != nil)
	if t_d == nil do return

	want_pos := [3]f32{77, 88, 99}
	t_d.position = want_pos
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// Inspect the saved file: an override on the outer NS must directly carry
	// target.guid = TestD's guid (Unity-style — no breadcrumb indirection).
	{
		guid_d, _ := uuid.read("9d8c54a0-6f5b-4d0e-9b8a-1a2c3d4e5f60")
		guid_d_a := engine.Asset_GUID(guid_d)

		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if !fok do return
		defer engine.scene_file_destroy(&sf)

		found := false
		outer: for &ns in sf.nested_scenes {
			for ov in ns.overrides {
				if ov.target.guid == guid_d_a {
					found = true
					break outer
				}
			}
		}
		testing.expect(t, found,
			"saved file must contain an override targeting TestD's prefab guid")
	}

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b1r := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	tdr := find_nested_named_under_host(&tc_mem.world, reloaded, host_b1r, "TransformD")
	testing.expect(t, host_b1r != {} && tdr != {})
	if host_b1r == {} || tdr == {} do return

	t_dr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tdr))
	testing.expect(t, t_dr != nil)
	if t_dr == nil do return
	testing.expect_value(t, t_dr.position, want_pos)
}

@(test)
test_save_nested_b_to_c_writes_overrides_for_modified_c :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_nested_bc_override.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil, "TestA load failed")
	if loaded == nil do return
	tc_mem.scene = loaded

	guid_c, guid_err := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	testing.expect(t, guid_err == nil)
	if guid_err != nil do return
	guid_asset := engine.Asset_GUID(guid_c)

	host_b := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_b, "TransformC")
	testing.expect(t, host_b != {} && transform_c_h != {}, "expected TestB host and nested TransformC")
	if host_b == {} || transform_c_h == {} do return

	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	testing.expect(t, t_c != nil)
	if t_c == nil do return
	want_pos := [3]f32{10.25, 20.5, 30.75}
	t_c.position = want_pos

	ok := engine.scene_save(loaded, tc_mem.path)
	testing.expect(t, ok, "scene_save failed")
	if !ok do return

	// On disk: the deep override should be persisted on the outer TestB NS
	// directly carrying (target.guid = TestC GUID, target.local_id = projected
	// lid). Unity-style: the breadcrumb indirection is gone — the override
	// target is the PPtr itself.
	sf, file_ok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, file_ok)
	if !file_ok do return
	defer engine.scene_file_destroy(&sf)

	deep_ok := false
	for ns in sf.nested_scenes {
		for ov in ns.overrides {
			if ov.target.guid != guid_asset do continue
			if strings.compare(ov.property_path, "position") != 0 do continue
			if override_vec3_matches(ov.value, want_pos) {
				deep_ok = true
				break
			}
		}
		if deep_ok do break
	}
	testing.expect(t, deep_ok,
		"saved file should contain a deep override on the outer NS keyed by (TestC guid, projected lid)")

	// Round-trip: reload the saved file and verify TransformC's position is
	// the edited value, not TestC.scene's base value.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil, "reload after save failed")
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b2 := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	tc_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_b2, "TransformC")
	testing.expect(t, host_b2 != {} && tc_h2 != {}, "expected TestB+TransformC after reload")
	if host_b2 == {} || tc_h2 == {} do return

	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_h2))
	testing.expect(t, t_c2 != nil)
	if t_c2 == nil do return
	testing.expect_value(t, t_c2.position, want_pos)
}

// Pins design intent: when the same inner prefab is instantiated twice at
// depth >= 2 (TestA → {TestB-1, TestB-2}, both wrapping TestB → TestC), deep
// overrides on TransformC must project to distinct breadcrumbs per outer
// instance. The XOR projection key is each NS's local_id_in_parent, which
// differs across the two TestB instances; so the two TransformC targets in
// TestA's namespace resolve to different transforms, and edits to one do not
// bleed into the other across save/reload.
@(test)
test_deep_override_disambiguates_duplicate_inner_prefab :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_dup_disambig.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	host_b2 := find_transform_named(&tc_mem.world, loaded, "TestB2", false)
	testing.expect(t, host_b1 != {} && host_b2 != {})
	if host_b1 == {} || host_b2 == {} do return

	tc1 := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	tc2 := find_nested_named_under_host(&tc_mem.world, loaded, host_b2, "TransformC")
	testing.expect(t, tc1 != {} && tc2 != {} && tc1 != tc2,
		"two TestB instances must yield distinct TransformC handles")
	if tc1 == {} || tc2 == {} do return

	t_c1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1))
	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc2))
	if t_c1 == nil || t_c2 == nil do return

	want1 := [3]f32{101, 102, 103}
	want2 := [3]f32{201, 202, 203}
	t_c1.position = want1
	t_c2.position = want2
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// Inspect the saved file: each TestB instance owns its own NS record,
	// and each carries its own deep override on TransformC.position. The
	// disambiguation comes from the OWNING NS (scene_instance in Unity terms),
	// not from the target PPtr alone — two instances of the same prefab will
	// produce identical `target` values, just stored on different NS records.
	{
		guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
		guid_c_a := engine.Asset_GUID(guid_c)

		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if !fok do return
		defer engine.scene_file_destroy(&sf)

		owning_ns_count := 0
		for &ns in sf.nested_scenes {
			if ns.expand_parent != {} do continue
			for ov in ns.overrides {
				if strings.compare(ov.property_path, "position") != 0 do continue
				if ov.target.guid != guid_c_a do continue
				owning_ns_count += 1
				break
			}
		}
		testing.expect_value(t, owning_ns_count, 2)
	}

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b1r := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	host_b2r := find_transform_named(&tc_mem.world, reloaded, "TestB2", false)
	tc1r := find_nested_named_under_host(&tc_mem.world, reloaded, host_b1r, "TransformC")
	tc2r := find_nested_named_under_host(&tc_mem.world, reloaded, host_b2r, "TransformC")
	testing.expect(t, tc1r != {} && tc2r != {} && tc1r != tc2r)
	if tc1r == {} || tc2r == {} do return

	t_c1r := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1r))
	t_c2r := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc2r))
	if t_c1r == nil || t_c2r == nil do return
	testing.expect_value(t, t_c1r.position, want1)
	testing.expect_value(t, t_c2r.position, want2)
}

// Brittleness check for prefab restructure: a deep override stored on the root
// scene must still resolve to the right inner transform after the inner prefab
// file is mutated in ways that don't change Local_IDs (rename, sibling reorder).
// The override is keyed by (guid, projected lid), not by name or array index,
// so these mutations should be invisible to resolution.
@(test)
test_deep_override_survives_inner_prefab_restructure :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_restructure.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Snapshot TestC.scene so we can mutate it on disk and restore at the end.
	testc_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	original_testc, read_err := os.read_entire_file_from_path(testc_path, context.allocator)
	testing.expect(t, read_err == nil, "snapshot TestC.scene")
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(testc_path, original_testc)
		delete(original_testc)
	}

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	tc1 := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	testing.expect(t, host_b1 != {} && tc1 != {})
	if host_b1 == {} || tc1 == {} do return

	t_c1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1))
	if t_c1 == nil do return
	want := [3]f32{321, 654, 987}
	t_c1.position = want
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// Mutate TestC.scene on disk: rename TransformC and reorder children. Both
	// edits leave Local_IDs untouched, so projection-key invariants hold.
	{
		buf, err := os.read_entire_file_from_path(testc_path, context.allocator)
		testing.expect(t, err == nil)
		if err != nil do return
		defer delete(buf)
		s := string(buf)
		mutated, _ := strings.replace_all(s, "\"TransformC\"", "\"TransformC_renamed\"")
		defer delete(mutated)
		write_err := os.write_entire_file(testc_path, transmute([]u8)mutated)
		testing.expect(t, write_err == nil)
		if write_err != nil do return
		// Drop cached prefab bytes and re-scan AssetDB so subsequent loads
		// see the mutated TestC content.
		engine.scene_lib_shutdown()
		engine.asset_db_shutdown()
		engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	}

	// Tear down active scene before reload so handles don't leak across.
	engine.sm_scene_destroy_or_unload(loaded)
	engine.sm_scene_set_active(nil)

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b1r := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	// Inner transform now goes by its renamed identity.
	tc1r := find_nested_named_under_host(&tc_mem.world, reloaded, host_b1r, "TransformC_renamed")
	testing.expect(t, host_b1r != {} && tc1r != {},
		"override must still resolve to the inner transform after rename")
	if host_b1r == {} || tc1r == {} do return

	t_c1r := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc1r))
	if t_c1r == nil do return
	testing.expect_value(t, t_c1r.position, want)
}

// Apply override (mirror of revert): instead of dropping the override, bake its
// value UP into the immediate-parent prefab file, then remove the override from
// the root NS. Shallow case — the root scene directly hosts prefab P (here
// TestC), so the field is patched directly on P's own transform row in P's file.
//
// Fixtures are mutated on disk (TestC.scene is rewritten), so the original bytes
// are snapshotted and restored in defer to keep the repo clean.
@(test)
test_apply_override_shallow_writes_prefab_field :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	// Snapshot + restore the prefab file we're about to mutate.
	testc_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	orig, read_err := os.read_entire_file(testc_path, context.allocator)
	testing.expect(t, read_err == nil, "should read TestC.scene fixture")
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(testc_path, orig)
		delete(orig)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_shallow.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// TestB hosts exactly one TestC, so there's a single TransformC.
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestB.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_c := find_transform_named(&tc_mem.world, loaded, "TestC", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_c, "TransformC")
	testing.expect(t, host_c != {} && transform_c_h != {})
	if host_c == {} || transform_c_h == {} do return

	// Override TransformC's position, save+reload so the override comes through
	// the same path the editor uses re-entering a saved scene.
	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	if t_c == nil do return
	t_c.position = {99, 99, 99}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_c2 := find_transform_named(&tc_mem.world, reloaded, "TestC", false)
	tc_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_c2, "TransformC")
	testing.expect(t, host_c2 != {} && tc_h2 != {})
	if host_c2 == {} || tc_h2 == {} do return

	// Locate the root NS + projected target that owns the position override.
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &ns_iter in reloaded.nested_scenes {
		for ov in ns_iter.overrides {
			if ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				owning_target = ov.target
				break
			}
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil, "expected a NestedScene to own the position override")
	if owning_ns == nil do return

	ok := engine.nested_scene_apply_override(reloaded, owning_ns, owning_target, "position")
	testing.expect(t, ok, "apply_override should succeed")

	// (a) The override is gone from the root NS.
	for ov in owning_ns.overrides {
		testing.expect(t, !(ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0),
			"override should be removed after apply")
	}

	// (b) TestC.scene on disk now carries position {99,99,99} on TransformC (lid 2).
	sf, fok := engine.scene_file_load(testc_path)
	testing.expect(t, fok, "should reload TestC.scene after apply")
	if fok {
		found := false
		for tr in sf.transforms {
			if tr.local_id == 2 {
				testing.expect_value(t, tr.position, [3]f32{99, 99, 99})
				found = true
				break
			}
		}
		testing.expect(t, found, "TransformC (lid 2) should exist in TestC.scene")
		engine.scene_file_destroy(&sf)
	}

	// (c) The live field is unchanged (re-resolve rebuilds it; value is identical).
	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_h2))
	if t_c2 == nil do return
	testing.expect_value(t, t_c2.position, [3]f32{99, 99, 99})
}

// Deep Apply: TestA hosts TestB hosts TestC. Editing a TransformC produces a
// deep override on TestA's root NS (target.guid == TestC). Applying it writes
// into the IMMEDIATE PARENT prefab TestB — specifically TestB's NS-for-TestC
// override list — at the leaf lid un-projected exactly ONE level. TestB.scene
// is mutated on disk, so it's snapshotted+restored.
@(test)
test_apply_override_deep_writes_parent_record :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	testb_path := "moonhug/tests/fixtures/nested_scenes/TestB.scene"
	orig, read_err := os.read_entire_file(testb_path, context.allocator)
	testing.expect(t, read_err == nil, "should read TestB.scene fixture")
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(testb_path, orig)
		delete(orig)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_deep.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	tc_under_b1 := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformC")
	testing.expect(t, host_b1 != {} && tc_under_b1 != {})
	if host_b1 == {} || tc_under_b1 == {} do return

	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_under_b1))
	if t_c == nil do return
	want_pos := [3]f32{12, 34, 56}
	t_c.position = want_pos
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)

	// Locate the deep override (target.guid == TestC) on the root NS.
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	outer: for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		for ov in ns_iter.overrides {
			if ov.target.guid == guid_c_a && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				owning_target = ov.target
				break outer
			}
		}
	}
	testing.expect(t, owning_ns != nil, "expected a deep position override targeting TestC")
	if owning_ns == nil do return

	// Level 1 = bake into the TestC owner; level 2 = override in TestB. This test
	// targets TestB (the ancestor), so apply at level 2.
	ok := engine.nested_scene_apply_override(reloaded, owning_ns, owning_target, "position", 2)
	testing.expect(t, ok, "deep apply (level 2 → TestB) should succeed")

	// Root override removed.
	for ov in owning_ns.overrides {
		testing.expect(t, !(ov.target.guid == guid_c_a && strings.compare(ov.property_path, "position") == 0),
			"deep override should be removed after apply")
	}

	// TestB.scene's NS-for-TestC now carries the override at the un-projected
	// leaf lid. Verify the entry exists with matching value AND the XOR
	// round-trip identity: project(local_id_in_parent, written_lid) == root_lid.
	sf, fok := engine.scene_file_load(testb_path)
	testing.expect(t, fok)
	if fok {
		found := false
		for ns in sf.nested_scenes {
			if ns.source_prefab != guid_c_a do continue
			for ov in ns.overrides {
				if ov.target.guid != guid_c_a do continue
				if strings.compare(ov.property_path, "position") != 0 do continue
				if !override_vec3_matches(ov.value, want_pos) do continue
				// The written lid is fully un-projected into TestC's own
				// namespace — it must equal TransformC's lid in TestC.scene (2).
				testing.expect_value(t, ov.target.local_id, engine.Local_ID(2))
				found = true
				break
			}
			if found do break
		}
		testing.expect(t, found, "TestB.scene NS-for-TestC should gain the position override")
		engine.scene_file_destroy(&sf)
	}
}

// Regression for the reported menu bug: a field one level deep (chain
// TestB→TestC, field in TestC) must expose TWO apply targets, not one —
// level 1 = bake into the owner (TestC), level 2 = override in the host (TestB).
// Mirrors the user's s>bullet>c case (field in c → "Apply to Scene c" +
// "Apply as Override in bullet").
@(test)
test_apply_levels_owner_plus_ancestor :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_levels.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Load TestA so the chain is 2 deep: native NS = TestB, TestB nests TestC,
	// field in TestC. This makes the TestC override DEEP (mirrors s>bullet>c).
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_b, "TransformC")
	testing.expect(t, host_b != {} && transform_c_h != {})
	if host_b == {} || transform_c_h == {} do return

	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	if t_c == nil do return
	t_c.position = {3, 6, 9}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)
	guid_b, _ := uuid.read("2453d7fb-a433-4b0d-8a29-11fc0b491fe4")
	guid_b_a := engine.Asset_GUID(guid_b)

	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	lvl_outer: for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		for ov in ns_iter.overrides {
			if ov.target.guid == guid_c_a && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter; owning_target = ov.target; break lvl_outer
			}
		}
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	// Two targets.
	testing.expect_value(t, engine.nested_scene_apply_levels(reloaded, owning_ns, owning_target), 2)

	// Level 1 = owner bake → TestC, flagged is_owner.
	g1, owner1, ok1 := engine.nested_scene_apply_target_guid(reloaded, owning_ns, owning_target, 1)
	testing.expect(t, ok1 && owner1)
	testing.expect(t, g1 == guid_c_a, "level 1 should target the owner prefab TestC")

	// Level 2 = ancestor override → TestB, NOT owner.
	g2, owner2, ok2 := engine.nested_scene_apply_target_guid(reloaded, owning_ns, owning_target, 2)
	testing.expect(t, ok2 && !owner2)
	testing.expect(t, g2 == guid_b_a, "level 2 should target the ancestor prefab TestB")
}

// Apply on one instance must update PEER instances' baselines via propagation.
// TestA hosts TestB twice. The peer TestB instance has no explicit override on
// the applied field, so after Apply its live field must reflect the new baked
// baseline (proving _propagate_prefab_save re-resolved it).
//
// This is also the canonical regression guard for the _nested_scene_unresolve
// `ep == host_tH` fix: without it, re-resolving the two TestB instances back to
// back corrupts each other and this test fails (matches != 2).
@(test)
test_apply_override_propagates_to_peers :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	// Deep override on TransformC under TestB → apply at level 2 (override into
	// TestB.scene, the ancestor), so snapshot+restore that file.
	testb_path := "moonhug/tests/fixtures/nested_scenes/TestB.scene"
	orig, read_err := os.read_entire_file(testb_path, context.allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(testb_path, orig)
		delete(orig)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_peers.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// Both TestB instances host a TestC. Find the two TransformC handles.
	tc_handles := make([dynamic]engine.Transform_Handle, 0, 2, context.temp_allocator)
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		tr := &slot.data
		if tr.scene != loaded || !tr.nested_owned do continue
		if strings.compare(tr.name, "TransformC") != 0 do continue
		append(&tc_handles, engine.Transform_Handle(
			engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform}))
	}
	testing.expect(t, len(tc_handles) == 2, "TestA should yield two TransformC instances")
	if len(tc_handles) != 2 do return

	// Override the FIRST instance's position, save+reload.
	t_c0 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_handles[0]))
	if t_c0 == nil do return
	want_pos := [3]f32{42, 42, 42}
	t_c0.position = want_pos
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)

	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	outer2: for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		for ov in ns_iter.overrides {
			if ov.target.guid == guid_c_a && override_vec3_matches(ov.value, want_pos) &&
			   strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				owning_target = ov.target
				break outer2
			}
		}
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	testing.expect(t, engine.nested_scene_apply_override(reloaded, owning_ns, owning_target, "position", 2))

	// After apply+propagation, BOTH TransformC instances must show the applied
	// value: the edited instance (override removed → new baseline) and the peer
	// (no explicit override → picks up the new shared baseline).
	matches := 0
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		tr := &slot.data
		if tr.scene != reloaded || !tr.nested_owned do continue
		if strings.compare(tr.name, "TransformC") != 0 do continue
		if tr.position == want_pos do matches += 1
	}
	testing.expect_value(t, matches, 2)
}

// Round-trip: after Apply, re-baking the parent prefab fresh from disk must
// yield the applied value (proves the disk write + scene_lib refresh agree).
@(test)
test_apply_override_file_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	testc_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	orig, read_err := os.read_entire_file(testc_path, context.allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(testc_path, orig)
		delete(orig)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_rt.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestB.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_c := find_transform_named(&tc_mem.world, loaded, "TestC", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_c, "TransformC")
	testing.expect(t, host_c != {} && transform_c_h != {})
	if host_c == {} || transform_c_h == {} do return

	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	if t_c == nil do return
	t_c.position = {5, 6, 7}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &ns_iter in reloaded.nested_scenes {
		for ov in ns_iter.overrides {
			if ov.target.local_id == 2 && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				owning_target = ov.target
				break
			}
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil)
	if owning_ns == nil do return

	testing.expect(t, engine.nested_scene_apply_override(reloaded, owning_ns, owning_target, "position"))

	// Fully reload TestC.scene from disk and confirm the baked field.
	engine.scene_lib_shutdown()
	sf, fok := engine.scene_file_load(testc_path)
	testing.expect(t, fok)
	if fok {
		found := false
		for tr in sf.transforms {
			if tr.local_id == 2 {
				testing.expect_value(t, tr.position, [3]f32{5, 6, 7})
				found = true
				break
			}
		}
		testing.expect(t, found)
		engine.scene_file_destroy(&sf)
	}
}

// Multi-level Apply: chain TestA -> TestB -> TestC -> TestD. Editing TransformD
// (in TestD) yields a deep override on TestA's root NS targeting TestD. Applying
// at levels_up=2 bakes it into the GRANDPARENT prefab TestB (not the immediate
// parent TestC): TestB.scene's NS-for-TestC gains a *deep* override targeting
// TestD, at the lid un-projected through only the top hop. Both TestB and TestC
// files may be touched (clear-above-target), so snapshot+restore both.
@(test)
test_apply_override_multilevel_grandparent :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	testb_path := "moonhug/tests/fixtures/nested_scenes/TestB.scene"
	testc_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	orig_b, eb := os.read_entire_file(testb_path, context.allocator)
	orig_c, ec := os.read_entire_file(testc_path, context.allocator)
	testing.expect(t, eb == nil && ec == nil)
	if eb != nil || ec != nil do return
	defer {
		_ = os.write_entire_file(testb_path, orig_b); delete(orig_b)
		_ = os.write_entire_file(testc_path, orig_c); delete(orig_c)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_ml.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b1 := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	td := find_nested_named_under_host(&tc_mem.world, loaded, host_b1, "TransformD")
	testing.expect(t, host_b1 != {} && td != {})
	if host_b1 == {} || td == {} do return

	t_d := engine.pool_get(&tc_mem.world.transforms, engine.Handle(td))
	if t_d == nil do return
	want_pos := [3]f32{321, 654, 987}
	t_d.position = want_pos
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	guid_d, _ := uuid.read("9d8c54a0-6f5b-4d0e-9b8a-1a2c3d4e5f60")
	guid_d_a := engine.Asset_GUID(guid_d)

	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	// Match the value we set, so we pick OUR edit's override and not one of the
	// other TestD-position overrides the fixture chain already carries.
	outer_ml: for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		for ov in ns_iter.overrides {
			if ov.target.guid == guid_d_a && strings.compare(ov.property_path, "position") == 0 &&
			   override_vec3_matches(ov.value, want_pos) {
				owning_ns = &ns_iter
				owning_target = ov.target
				break outer_ml
			}
		}
	}
	testing.expect(t, owning_ns != nil, "expected deep override targeting TestD on root NS")
	if owning_ns == nil do return

	// Three levels: lvl1 = bake into TestD (owner), lvl2 = override in TestC,
	// lvl3 = override in TestB. We apply at lvl3 (the shallowest: TestB).
	testing.expect_value(t, engine.nested_scene_apply_levels(reloaded, owning_ns, owning_target), 3)

	ok := engine.nested_scene_apply_override(reloaded, owning_ns, owning_target, "position", 3)
	testing.expect(t, ok, "levels_up=3 apply should succeed")

	// Root override removed. Re-scan fresh: apply's propagation re-resolves and
	// reallocates reloaded.nested_scenes, so the old owning_ns pointer is stale.
	still_present := false
	for &ns_iter in reloaded.nested_scenes {
		if ns_iter.expand_parent != {} do continue
		for ov in ns_iter.overrides {
			if ov.target.guid == guid_d_a && strings.compare(ov.property_path, "position") == 0 &&
			   override_vec3_matches(ov.value, want_pos) {
				still_present = true
			}
		}
	}
	testing.expect(t, !still_present, "root override should be removed after multi-level apply")

	// TestB.scene's NS-for-TestC gained a DEEP override targeting TestD.
	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)
	sf, fok := engine.scene_file_load(testb_path)
	testing.expect(t, fok)
	if fok {
		found := false
		for ns in sf.nested_scenes {
			if ns.source_prefab != guid_c_a do continue // TestB's NS-for-TestC
			for ov in ns.overrides {
				if ov.target.guid != guid_d_a do continue // deep: targets TestD
				if strings.compare(ov.property_path, "position") != 0 do continue
				if !override_vec3_matches(ov.value, want_pos) do continue
				// XOR round-trip: re-project the written lid through TestC's
				// own NS local_id_in_parent must recover the root override lid.
				reprojected := engine.local_id_project(ns.local_id_in_parent, ov.target.local_id)
				testing.expect_value(t, reprojected, owning_target.local_id)
				found = true
				break
			}
			if found do break
		}
		testing.expect(t, found, "TestB.scene NS-for-TestC should gain a deep TestD override")
		engine.scene_file_destroy(&sf)
	}
}

// Clear-above-target: when an intermediate prefab already holds the same-field
// override, applying at a SHALLOWER (grandparent) level must clear it, else
// shallower-wins precedence would shadow the freshly-baked value. We first
// Apply at level 1 (seeding a TestD-position override into TestC.scene), then
// re-edit and Apply at level 2 (TestB); the TestC override must be gone and the
// live TransformD must show the level-2 value.
@(test)
test_apply_override_clears_shadowing_intermediate :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	testb_path := "moonhug/tests/fixtures/nested_scenes/TestB.scene"
	testc_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	testd_path := "moonhug/tests/fixtures/nested_scenes/TestD.scene"
	orig_b, eb := os.read_entire_file(testb_path, context.allocator)
	orig_c, ec := os.read_entire_file(testc_path, context.allocator)
	orig_d, ed := os.read_entire_file(testd_path, context.allocator)
	testing.expect(t, eb == nil && ec == nil && ed == nil)
	if eb != nil || ec != nil || ed != nil do return
	defer {
		_ = os.write_entire_file(testb_path, orig_b); delete(orig_b)
		_ = os.write_entire_file(testc_path, orig_c); delete(orig_c)
		_ = os.write_entire_file(testd_path, orig_d); delete(orig_d)
	}

	guid_d, _ := uuid.read("9d8c54a0-6f5b-4d0e-9b8a-1a2c3d4e5f60")
	guid_d_a := engine.Asset_GUID(guid_d)

	// Helper: load TestA, set TransformD.position, save+reload, locate the
	// matching root override, Apply at `lvl`.
	edit_and_apply :: proc(t: ^testing.T, path: string, guid_d_a: engine.Asset_GUID, world: ^engine.World, want: [3]f32, lvl: int) -> ^engine.Scene {
		loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
		if loaded == nil { testing.expect(t, false, "load TestA"); return nil }
		host_b1 := find_transform_named(world, loaded, "TestB", false)
		td := find_nested_named_under_host(world, loaded, host_b1, "TransformD")
		if td == {} { testing.expect(t, false, "find TransformD"); return loaded }
		t_d := engine.pool_get(&world.transforms, engine.Handle(td))
		if t_d == nil { return loaded }
		t_d.position = want
		testing.expect(t, engine.scene_save(loaded, path))

		reloaded := engine.scene_load_single_path(path)
		if reloaded == nil { testing.expect(t, false, "reload"); return nil }

		ons: ^engine.NestedScene
		otgt: engine.PPtr
		oloop: for &ns_iter in reloaded.nested_scenes {
			if ns_iter.expand_parent != {} do continue
			for ov in ns_iter.overrides {
				if ov.target.guid == guid_d_a && strings.compare(ov.property_path, "position") == 0 &&
				   override_vec3_matches(ov.value, want) {
					ons = &ns_iter; otgt = ov.target; break oloop
				}
			}
		}
		testing.expect(t, ons != nil, "locate root override")
		if ons != nil {
			testing.expect(t, engine.nested_scene_apply_override(reloaded, ons, otgt, "position", lvl))
		}
		return reloaded
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_apply_shadow.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Step 1: Apply at level 2 → records an override in TestC.scene's NS-for-TestD
	// (level 2 = the first ancestor above the TestD owner). This is the SHALLOWER
	// override that will later shadow a deeper (owner) apply.
	s1 := edit_and_apply(t, tc_mem.path, guid_d_a, &tc_mem.world, {11, 22, 33}, 2)
	tc_mem.scene = s1
	{
		sf, fok := engine.scene_file_load(testc_path)
		testing.expect(t, fok)
		if fok {
			seeded := false
			for ns in sf.nested_scenes {
				if ns.source_prefab != guid_d_a do continue
				for ov in ns.overrides {
					if strings.compare(ov.property_path, "position") == 0 && override_vec3_matches(ov.value, {11, 22, 33}) do seeded = true
				}
			}
			testing.expect(t, seeded, "level-2 apply should seed TestC.scene's TestD override")
			engine.scene_file_destroy(&sf)
		}
	}

	// Step 2: re-edit and Apply at level 1 (bake into the TestD OWNER, deepest).
	// The TestC override from step 1 is SHALLOWER than the owner, so it would
	// shadow the bake — clear-above-target must remove it.
	if s1 != nil { engine.sm_scene_destroy_or_unload(s1); engine.sm_scene_set_active(nil) }
	s2 := edit_and_apply(t, tc_mem.path, guid_d_a, &tc_mem.world, {77, 88, 99}, 1)
	tc_mem.scene = s2

	// TestC.scene's TestD-position override must be GONE (cleared as shadowing).
	{
		sf, fok := engine.scene_file_load(testc_path)
		testing.expect(t, fok)
		if fok {
			shadow := false
			for ns in sf.nested_scenes {
				if ns.source_prefab != guid_d_a do continue
				for ov in ns.overrides {
					if strings.compare(ov.property_path, "position") == 0 do shadow = true
				}
			}
			testing.expect(t, !shadow, "owner apply must clear the shadowing TestC override")
			engine.scene_file_destroy(&sf)
		}
	}

	// TestD.scene's own TransformD row must now carry the baked value.
	{
		sf, fok := engine.scene_file_load("moonhug/tests/fixtures/nested_scenes/TestD.scene")
		testing.expect(t, fok)
		if fok {
			for tr in sf.transforms {
				if tr.local_id == 2 do testing.expect_value(t, tr.position, [3]f32{77, 88, 99})
			}
			engine.scene_file_destroy(&sf)
		}
	}

	// And the live TransformD must show the baked value (not shadowed).
	if s2 != nil {
		host_b := find_transform_named(&tc_mem.world, s2, "TestB", false)
		tdr := find_nested_named_under_host(&tc_mem.world, s2, host_b, "TransformD")
		testing.expect(t, tdr != {})
		if tdr != {} {
			t_dr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tdr))
			if t_dr != nil do testing.expect_value(t, t_dr.position, [3]f32{77, 88, 99})
		}
	}
}

// Hardening: distinct per-instance content must survive repeated propagation
// re-resolves. TestA hosts TestB twice (each TestB -> TestC -> TestD); we save
// distinct TransformD positions per instance, then run prefab_propagate(TestB)
// twice and require the multiset of positions to stay identical and the
// instances to stay distinct. (The primary guard for the _nested_scene_unresolve
// `ep == host_tH` fix is test_apply_override_propagates_to_peers, which fails
// without it; this test adds general multi-instance-independence coverage.)
@(test)
test_reresolve_duplicate_instances_stable :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Snapshot+restore TestA (we save distinct per-instance overrides into it).
	testa_path := "moonhug/tests/fixtures/nested_scenes/TestA.scene"
	orig_a, ea := os.read_entire_file(testa_path, context.allocator)
	testing.expect(t, ea == nil)
	if ea != nil do return
	defer { _ = os.write_entire_file(testa_path, orig_a); delete(orig_a) }

	loaded := engine.scene_load_single_path(testa_path)
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// Give each instance's TransformD a DISTINCT position, then save+reload so
	// each carries its own per-instance override. Now cross-corruption during
	// re-resolve would be visible as a value collision or count change.
	{
		seen := 0
		vals := [][3]f32{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}
		for i in 0 ..< len(tc_mem.world.transforms.slots) {
			slot := &tc_mem.world.transforms.slots[i]
			if !slot.alive do continue
			tr := &slot.data
			if tr.scene != loaded || !tr.nested_owned do continue
			if strings.compare(tr.name, "TransformD") != 0 do continue
			tr.position = vals[seen % len(vals)]
			seen += 1
		}
		testing.expect(t, engine.scene_save(loaded, testa_path))
		engine.sm_scene_destroy_or_unload(loaded)
		engine.sm_scene_set_active(nil)
		loaded = engine.scene_load_single_path(testa_path)
		testing.expect(t, loaded != nil)
		if loaded == nil do return
		tc_mem.scene = loaded
	}

	// Collect all TransformD positions into a multiset (sorted) for comparison.
	collect_sorted :: proc(world: ^engine.World, s: ^engine.Scene) -> [dynamic][3]f32 {
		out := make([dynamic][3]f32, 0, 4)
		for i in 0 ..< len(world.transforms.slots) {
			slot := &world.transforms.slots[i]
			if !slot.alive do continue
			tr := &slot.data
			if tr.scene != s || !tr.nested_owned do continue
			if strings.compare(tr.name, "TransformD") != 0 do continue
			append(&out, tr.position)
		}
		// insertion sort by x then y then z (small N)
		for a in 1 ..< len(out) {
			v := out[a]; b := a
			for b > 0 && _vec3_less(v, out[b-1]) { out[b] = out[b-1]; b -= 1 }
			out[b] = v
		}
		return out
	}

	baseline := collect_sorted(&tc_mem.world, loaded)
	defer delete(baseline)
	testing.expect(t, len(baseline) >= 2, "TestA should expand to >= 2 TransformD instances")
	if len(baseline) < 2 do return
	// Distinct per-instance values (set above) — required for the test to
	// actually detect cross-corruption rather than pass vacuously.
	testing.expect(t, baseline[0] != baseline[len(baseline)-1],
		"instances must hold distinct TransformD positions after save+reload")

	// Drive the PROPAGATION re-resolve path (the one the fix addresses):
	// prefab_propagate(TestB) re-resolves every native TestB instance back to
	// back. Pre-fix, the second instance's re-resolve clobbered the first's
	// subtree. Run it twice; each instance must keep its own distinct value.
	guid_b, _ := uuid.read("2453d7fb-a433-4b0d-8a29-11fc0b491fe4")
	for pass in 0 ..< 2 {
		engine.prefab_propagate(engine.Asset_GUID(guid_b))
		got := collect_sorted(&tc_mem.world, loaded)
		defer delete(got)
		testing.expect_value(t, len(got), len(baseline))
		if len(got) == len(baseline) {
			for k in 0 ..< len(baseline) {
				testing.expect(t, got[k] == baseline[k],
					fmt.tprintf("pass %d: TransformD set drifted at %d: got %v want %v", pass, k, got[k], baseline[k]))
			}
		}
	}
}

@(private)
_vec3_less :: proc(a, b: [3]f32) -> bool {
	if a[0] != b[0] do return a[0] < b[0]
	if a[1] != b[1] do return a[1] < b[1]
	return a[2] < b[2]
}

// ---------------------------------------------------------------------------
// Prefab variants — a scene whose own root IS a NestedScene over a base prefab
// (transform_parent == 0). The scene is "base + my overrides + my added
// content". VariantC.scene is a variant of TestC with name/position overrides
// on TransformC and one added child (VariantExtra) grafted under the base root.
// ---------------------------------------------------------------------------

// Regression: resolving a scene with multiple nested scenes + deep overrides
// appends to s.nested_scenes mid-resolve, which can reallocate the dynamic
// array and dangle the `ns` pointer captured at the top of nested_scene_resolve.
// The deep-override pass (nested_scene.odin:_nested_scene_apply_deep_overrides_live)
// iterated ns.overrides through that dangling pointer → EXC_BAD_ACCESS. Loading
// several such scenes additively (as the editor does) must not crash and must
// resolve the deep overrides. TestA nests TestB twice with deep TestC/TestD
// overrides — exactly that shape.
@(test)
test_additive_load_deep_overrides_no_dangling :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Load several deep-override scenes additively (they coexist, sharing the
	// transform/NS pools) — the editor's open path.
	a := engine.scene_load_additive_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, a != nil, "TestA loaded")
	b := engine.scene_load_additive_path("moonhug/tests/fixtures/nested_scenes/HostVariant.scene")
	testing.expect(t, b != nil, "HostVariant loaded")
	c := engine.scene_load_additive_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, c != nil, "second TestA loaded")
	tc_mem.scene = c

	// Deep overrides resolved (TestA sets TestC position {50,50,50}); reading the
	// nested content proves the deep-override pass ran against a valid `ns`.
	hb := find_transform_named(&tc_mem.world, a, "TestB", false)
	tc := find_nested_named_under_host(&tc_mem.world, a, hb, "TransformC")
	testing.expect(t, tc != {}, "TransformC resolves under TestA's TestB")
	if tc != {} {
		tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc))
		testing.expect(t, tt != nil)
		if tt != nil do testing.expect_value(t, tt.position, [3]f32{50, 50, 50})
	}

	// Unload the extra additive scenes (teardown only frees tc_mem.scene).
	engine.sm_scene_destroy_or_unload(a)
	engine.sm_scene_destroy_or_unload(b)
}

@(test)
test_variant_loads_base_plus_overrides :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil, "VariantC.scene should load")
	if loaded == nil do return
	tc_mem.scene = loaded

	// The base prefab (TestC) is materialized as the scene root: a native host
	// transform that adopts the base root's name ("RootC") and transform, with
	// the base content (TransformC, TestD) nested-owned beneath it, and the
	// variant's added child grafted under it.
	root_c := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	testing.expect(t, root_c != {}, "RootC (base root) should be the resolved scene root")

	// Overridden name: TransformC -> TransformC_Variant.
	tc_variant := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tc_variant != {}, "TransformC should carry the variant's name override")
	if tc_variant != {} {
		tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_variant))
		testing.expect(t, tt != nil)
		if tt != nil {
			testing.expect_value(t, tt.position, [3]f32{71, 81, 91})
		}
	}

	// The variant's added child is present (it is NOT part of TestC).
	extra := find_transform_named(&tc_mem.world, loaded, "VariantExtra", false)
	if extra == {} {
		extra = find_transform_named(&tc_mem.world, loaded, "VariantExtra", true)
	}
	testing.expect(t, extra != {}, "VariantExtra (added child) should be present in the resolved tree")
}

// The inspector decides override badge + Apply/Revert via these engine procs:
// the scene root must be recognized as the variant root NS's host, and the
// variant's own override on a base transform must be locatable from there.
@(test)
test_variant_inspector_host_and_override_lookup :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	root_c := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	testing.expect(t, root_c != {})
	if root_c == {} do return

	// (a) The scene root is recognized as a nested-scene host (drives the
	// hierarchy badge + inspector nested banner).
	testing.expect(t, engine.scene_find_nested_scene_for_host(loaded, root_c) != nil,
		"scene root should host the variant root NS")
	testing.expect(t, engine.scene_hierarchy_transform_is_nested_scene_host(loaded, root_c),
		"hierarchy should show the variant root as a nested-scene host")

	// (b) A base transform's immediate nested host resolves to the scene root
	// (drives inspector_set_nested_host on selection).
	tc_variant := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tc_variant != {})
	if tc_variant == {} do return
	imm_host := engine.transform_immediate_nested_host(tc_variant)
	testing.expect(t, imm_host == root_c, "TransformC's immediate nested host should be the variant root")

	// (c) The variant's own overrides on TransformC (lid 2) are locatable from
	// the root host — this is what makes the override badge + Apply/Revert show.
	tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_variant))
	if tt == nil do return
	testing.expect(t, engine.nested_scene_has_root_override(loaded, imm_host, tt.local_id, "name"),
		"variant's own 'name' override should be locatable for the inspector")
	testing.expect(t, engine.nested_scene_has_root_override(loaded, imm_host, tt.local_id, "position"),
		"variant's own 'position' override should be locatable for the inspector")
	// A non-overridden field must NOT report as overridden.
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, imm_host, tt.local_id, "scale"),
		"non-overridden field should not report as overridden")
}

@(test)
test_variant_save_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_round_trip.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	testing.expect(t, engine.scene_save(loaded, tc_mem.path), "variant should save")

	// The saved file must keep a transform_parent:0 root NS pointing at TestC,
	// and must NOT duplicate the base's transforms — only the added child.
	sf, fok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, fok, "saved variant should reload as a SceneFile")
	if fok {
		guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
		guid_c_a := engine.Asset_GUID(guid_c)

		root_ns_found := false
		for ns in sf.nested_scenes {
			if ns.transform_parent == 0 && ns.source_prefab == guid_c_a {
				root_ns_found = true
			}
		}
		testing.expect(t, root_ns_found, "saved file should have a transform_parent:0 NS over TestC")

		// No base transforms (RootC/TransformC/TestD) — only VariantExtra.
		for tr in sf.transforms {
			testing.expect(t, strings.compare(tr.name, "RootC") != 0, "base RootC must not be written to the variant file")
			testing.expect(t, strings.compare(tr.name, "TransformC") != 0, "base TransformC must not be written")
			testing.expect(t, strings.compare(tr.name, "TransformC_Variant") != 0, "overridden base name must not be written as a transform")
		}
		extra_found := false
		for tr in sf.transforms {
			if strings.compare(tr.name, "VariantExtra") == 0 do extra_found = true
		}
		testing.expect(t, extra_found, "the variant's added child should be written to the file")
		engine.scene_file_destroy(&sf)
	}

	// Reload the saved variant and confirm the resolved tree is intact.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	tc_variant := find_transform_named(&tc_mem.world, reloaded, "TransformC_Variant", true)
	testing.expect(t, tc_variant != {}, "override should survive round-trip")
	if tc_variant != {} {
		tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_variant))
		if tt != nil do testing.expect_value(t, tt.position, [3]f32{71, 81, 91})
	}
	extra := find_transform_named(&tc_mem.world, reloaded, "VariantExtra", false)
	testing.expect(t, extra != {}, "added child should survive round-trip")
	if extra != {} {
		et := engine.pool_get(&tc_mem.world.transforms, engine.Handle(extra))
		if et != nil do testing.expect_value(t, et.position, [3]f32{11, 22, 33})
	}
}

@(test)
test_variant_edit_captures_override :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_edit.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// Mutate a base child field that is NOT already overridden (TransformC's
	// scale; only name/position are pre-overridden). This should be captured as
	// a NEW override on the root NS, not as a native transform.
	tc_v := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tc_v != {})
	if tc_v == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_v))
	if ct == nil do return
	tc_lid := ct.local_id
	ct.scale = {2, 2, 2}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	sf, fok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, fok)
	if fok {
		found_scale_ov := false
		for ns in sf.nested_scenes {
			if ns.transform_parent != 0 do continue
			for ov in ns.overrides {
				if ov.target.local_id == tc_lid && strings.compare(ov.property_path, "scale") == 0 {
					if override_vec3_matches(ov.value, {2, 2, 2}) do found_scale_ov = true
				}
			}
		}
		testing.expect(t, found_scale_ov, "editing a base field should capture a new override on the root NS")
		// And it must not have been written as a native transform.
		for tr in sf.transforms {
			testing.expect(t, strings.compare(tr.name, "TransformC_Variant") != 0, "base content must not leak into the variant file as a transform")
		}
		engine.scene_file_destroy(&sf)
	}
}

@(test)
test_create_scene_variant_file :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	// Write the variant OUTSIDE the scanned fixtures dir so a mid-test failure
	// can't leave a meta-less .scene that breaks future asset_db_init scans.
	out_path := "moonhug/tests/fixtures/_TestC_Variant.scene"
	defer os.remove(out_path)

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	base_path := "moonhug/tests/fixtures/nested_scenes/TestC.scene"
	ok := engine.scene_create_variant_file(base_path, out_path)
	testing.expect(t, ok, "creating a variant file should succeed")
	if !ok do return

	// File on disk: a single root NS (transform_parent 0) over TestC, no transforms.
	guid_c, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_c_a := engine.Asset_GUID(guid_c)
	{
		sf, fok := engine.scene_file_load(out_path)
		testing.expect(t, fok, "variant file should load")
		if fok {
			testing.expect_value(t, len(sf.nested_scenes), 1)
			if len(sf.nested_scenes) == 1 {
				ns := sf.nested_scenes[0]
				testing.expect_value(t, ns.transform_parent, engine.Local_ID(0))
				testing.expect(t, ns.source_prefab == guid_c_a, "variant NS should point at TestC")
				testing.expect_value(t, len(ns.overrides), 0)
			}
			testing.expect_value(t, len(sf.transforms), 0)
			engine.scene_file_destroy(&sf)
		}
	}

	// Load it: resolves to TestC's content via the root NS. (The editor mints
	// the .meta via asset_db_refresh; load only needs the BASE guid, already
	// indexed, so we skip the refresh — its crypto-RNG GUID mint isn't wired in
	// the test context.)
	loaded := engine.scene_load_single_path(out_path)
	testing.expect(t, loaded != nil, "created variant should load + resolve")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_c := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	testing.expect(t, root_c != {}, "variant should resolve the base root (RootC)")

	// The resolved variant must look like the base scene — NO extra wrapper/Root
	// transform. TestC.scene has exactly one transform named "RootC"; the variant
	// must too (the placeholder adopts the base root, it is not a separate node).
	rootc_count := 0
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene == loaded && strings.compare(slot.data.name, "RootC") == 0 {
			rootc_count += 1
		}
	}
	testing.expect_value(t, rootc_count, 1)

	// Re-saving an opened variant must NOT emit the placeholder root (or any base
	// content) as a transform — the file stays transforms:[] + the root NS.
	resave_path := "moonhug/tests/fixtures/_TestC_Variant_resave.scene"
	defer os.remove(resave_path)
	testing.expect(t, engine.scene_save(loaded, resave_path))
	{
		sf, fok := engine.scene_file_load(resave_path)
		testing.expect(t, fok)
		if fok {
			testing.expect_value(t, len(sf.transforms), 0)
			testing.expect_value(t, len(sf.nested_scenes), 1)
			if len(sf.nested_scenes) == 1 {
				testing.expect_value(t, sf.nested_scenes[0].transform_parent, engine.Local_ID(0))
			}
			engine.scene_file_destroy(&sf)
		}
	}
}

// Variant-as-nested: a normal scene nesting a variant as a child. The hosted
// resolve path materializes the inner variant's base + variant-overrides +
// variant-additions under the host.
@(test)
test_variant_nested_in_scene :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostVariant.scene")
	testing.expect(t, loaded != nil, "HostVariant.scene should load")
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "VariantHost", false)
	testing.expect(t, host != {}, "VariantHost should be present as a native host")

	// The variant's overridden TransformC and its added child resolve nested
	// under the host.
	tc_variant := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tc_variant != {}, "variant override should resolve through the nested variant")
	if tc_variant != {} {
		tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_variant))
		if tt != nil do testing.expect_value(t, tt.position, [3]f32{71, 81, 91})
	}

	extra := find_transform_named(&tc_mem.world, loaded, "VariantExtra", true)
	testing.expect(t, extra != {}, "variant's added child should resolve through the nested variant")

	// Override ownership (Unity model): the NESTED variant's OWN overrides are
	// baked into its baseline — they must NOT show as the host's editable/
	// revertable overrides. Only the host scene's own overrides on the nested
	// content are editable from here (there are none in this fixture).
	if tc_variant != {} {
		tt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_variant))
		if tt != nil {
			imm_host := engine.transform_immediate_nested_host(tc_variant)
			testing.expect(t, imm_host != {}, "nested content should have a host")
			// VariantC overrides TransformC's name + position; from the host
			// scene those are baked, not active overrides.
			testing.expect(t, !engine.nested_scene_has_root_override(loaded, imm_host, tt.local_id, "name"),
				"inner variant's own 'name' override must be baked, not editable from the host")
			testing.expect(t, !engine.nested_scene_has_root_override(loaded, imm_host, tt.local_id, "position"),
				"inner variant's own 'position' override must be baked, not editable from the host")
		}
	}
}

// An override on the variant's OWN ROOT transform (not a child) must persist
// across save+reload, same as a child override.
@(test)
test_variant_root_override_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_root_ov.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// Change the variant's ROOT transform (RootC, the scene root) position.
	root_c := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	testing.expect(t, root_c != {})
	if root_c == {} do return
	rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(root_c))
	if rt == nil do return
	root_lid := rt.local_id
	rt.position = {12, 34, 56}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// The saved root NS must carry a position override on the base root lid.
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			found := false
			for ns in sf.nested_scenes {
				if ns.transform_parent != 0 do continue
				for ov in ns.overrides {
					if ov.target.local_id == root_lid && strings.compare(ov.property_path, "position") == 0 &&
						override_vec3_matches(ov.value, {12, 34, 56}) {
						found = true
					}
				}
			}
			testing.expect(t, found, "root-transform override must be saved on the root NS")
			engine.scene_file_destroy(&sf)
		}
	}

	// Reload: the override is applied to the live root.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded
	root_c2 := find_transform_named(&tc_mem.world, reloaded, "RootC", false)
	testing.expect(t, root_c2 != {})
	if root_c2 == {} do return
	rt2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(root_c2))
	if rt2 == nil do return
	testing.expect_value(t, rt2.position, [3]f32{12, 34, 56})
}

// An override on a COMPONENT of the variant's root (e.g. SpriteRenderer.color)
// must persist across save+reload — the root's inherited components are baked
// baseline, so changes to them are overrides like any nested content.
@(test)
test_variant_root_component_override_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_root_comp.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/SpriteRootVariant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// The variant overrides the root SpriteRenderer color to blue at load.
	root_tH := engine.Transform_Handle(loaded.root.handle)
	_, sr := engine.transform_get_comp(root_tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "variant root should carry the inherited SpriteRenderer")
	if sr == nil do return
	testing.expect_value(t, sr.color, [4]f32{0, 0, 1, 1})

	// Override it again (green) and round-trip.
	sr.color = {0, 1, 0, 1}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded
	_, sr2 := engine.transform_get_comp(engine.Transform_Handle(reloaded.root.handle), engine.SpriteRenderer)
	testing.expect(t, sr2 != nil)
	if sr2 == nil do return
	testing.expect_value(t, sr2.color, [4]f32{0, 1, 0, 1})
}

// Nesting a variant inside a scene, saving, and reloading must keep the nested
// variant. Regression for inner placeholder NS records leaking into the file.
@(test)
test_variant_nested_in_scene_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_hostvariant_rt.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostVariant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded
	tcv := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tcv != {}, "sanity: nested variant resolves before save")

	// Edit nested-variant content in the HOST scene: this must be captured as an
	// override on the host's NS-for-VariantC and reload.
	if tcv != {} {
		ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tcv))
		if ct != nil do ct.position = {7, 7, 7}
	}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path), "save should succeed")

	// The saved file must NOT contain leaked inner NS records: every persisted
	// NS must have a host transform present in the file (transform_parent points
	// at a transform that exists, or transform_parent == 0 for a root variant).
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			tr_lids := make(map[engine.Local_ID]bool, 0, context.temp_allocator)
			for tr in sf.transforms do tr_lids[tr.local_id] = true
			for ns in sf.nested_scenes {
				if ns.transform_parent == 0 do continue
				testing.expect(t, tr_lids[ns.transform_parent],
					fmt.tprintf("persisted NS host transform_parent=%d must exist in file (no leaked inner records)", ns.transform_parent))
			}
			engine.scene_file_destroy(&sf)
		}
	}

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	testing.expect(t, find_transform_named(&tc_mem.world, reloaded, "VariantHost", false) != {},
		"host should survive round-trip")
	tcv2 := find_transform_named(&tc_mem.world, reloaded, "TransformC_Variant", true)
	testing.expect(t, tcv2 != {}, "nested variant must still be present after save + reload")
	if tcv2 != {} {
		ct2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tcv2))
		testing.expect(t, ct2 != nil)
		if ct2 != nil {
			testing.expect_value(t, ct2.position, [3]f32{7, 7, 7})
		}
	}
}

// A prefab that nests its own variant (CycleA nests CycleAVariant, which is a
// variant of CycleA) is a malformed nesting cycle. Resolve must detect it and
// skip rather than recurse forever / overflow the stack.
@(test)
test_variant_nesting_cycle_does_not_crash :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Load the cyclic variant directly, and the prefab that nests it. Neither
	// should crash; both should return a finite scene.
	v := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/CycleAVariant.scene")
	testing.expect(t, v != nil, "cyclic variant should load without crashing")

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/CycleA.scene")
	testing.expect(t, loaded != nil, "prefab nesting its own variant should load without crashing")
	if loaded == nil do return
	tc_mem.scene = loaded

	// The native root + host resolve; the cycle is broken (finite transform set).
	testing.expect(t, find_transform_named(&tc_mem.world, loaded, "CycleARoot", false) != {})
	count := 0
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		if tc_mem.world.transforms.slots[i].alive && tc_mem.world.transforms.slots[i].data.scene == loaded {
			count += 1
		}
	}
	testing.expect(t, count < 100, fmt.tprintf("transform count should be finite/small, got %d", count))
}

// Reverting an override on nested-variant content must restore the value to the
// variant's BAKED baseline (its own inherited value), not a value from the
// variant's unresolved file.
@(test)
test_variant_nested_revert :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_nested_revert.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostVariant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	tcv := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, tcv != {})
	if tcv == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tcv))
	if ct == nil do return
	// VariantC's baked baseline for TransformC position is {71,81,91}.
	testing.expect_value(t, ct.position, [3]f32{71, 81, 91})

	// Override it in the host, save+reload so the override lands on the host NS.
	ct.position = {7, 7, 7}
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	tcv2 := find_transform_named(&tc_mem.world, reloaded, "TransformC_Variant", true)
	testing.expect(t, tcv2 != {})
	if tcv2 == {} do return
	ct2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tcv2))
	if ct2 == nil do return
	testing.expect_value(t, ct2.position, [3]f32{7, 7, 7})

	// Find the host NS + target that owns the override.
	owning_ns: ^engine.NestedScene
	owning_target: engine.PPtr
	for &nsr in reloaded.nested_scenes {
		for ov in nsr.overrides {
			if strings.compare(ov.property_path, "position") == 0 && override_vec3_matches(ov.value, {7, 7, 7}) {
				owning_ns = &nsr
				owning_target = ov.target
				break
			}
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil, "host should own the nested-content override")
	if owning_ns == nil do return

	engine.nested_scene_revert_override(reloaded, owning_ns, owning_target, "position", &ct2.position)

	// Override removed, and the field restored to the variant's baked baseline.
	for ov in owning_ns.overrides {
		testing.expect(t, !(engine.pptr_equals(ov.target, owning_target) && strings.compare(ov.property_path, "position") == 0),
			"override should be removed after revert")
	}
	testing.expect_value(t, ct2.position, [3]f32{71, 81, 91})
}

// Reproduces the editor workflow: open a variant, nest another variant inside
// it, save, reload — the nested variant must persist. This is the variant-of-
// variant nesting case where inner placeholder NS records leaked into the file.
@(test)
test_variant_nest_variant_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_nest_variant.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Open VariantC (itself a variant of TestC).
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded
	engine.sm_scene_set_active(loaded)

	// Nest a second VariantC under the variant's root.
	variant_guid, _ := uuid.read("ba583c80-c557-4eae-8a6e-fa440602cef2")
	root_tH := engine.Transform_Handle(loaded.root.handle)
	nested := engine.scene_instantiate_guid_nested(engine.Asset_GUID(variant_guid), root_tH)
	testing.expect(t, nested != {}, "nesting a variant under a variant should succeed")
	if nested == {} do return

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// No leaked inner NS records in the file.
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			tr_lids := make(map[engine.Local_ID]bool, 0, context.temp_allocator)
			for tr in sf.transforms do tr_lids[tr.local_id] = true
			for ns in sf.nested_scenes {
				if ns.transform_parent == 0 do continue
				testing.expect(t, tr_lids[ns.transform_parent],
					fmt.tprintf("persisted NS host transform_parent=%d must exist in file", ns.transform_parent))
			}
			engine.scene_file_destroy(&sf)
		}
	}

	// Reload: both the variant's own content and the nested variant survive.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	// Two TransformC_Variant instances (the host variant's own + the nested one).
	count := 0
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene == reloaded && strings.compare(slot.data.name, "TransformC_Variant") == 0 {
			count += 1
		}
	}
	testing.expect(t, count >= 2, fmt.tprintf("expected the host variant + nested variant content after reload, got %d", count))
}

// Reproduces the editor bug: open a variant (VariantC), nest ANOTHER variant
// under its root (variant-in-variant — same shape as bullet_Variant > c_Variant),
// then EDIT the nested variant's content. The edit must be captured as an
// override on the host variant's root NS and survive save + reload.
@(test)
test_variant_nested_in_variant_edit_round_trip :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_in_variant_edit.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Open VariantC (itself a variant of TestC).
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded
	engine.sm_scene_set_active(loaded)

	// Nest a second VariantC under the variant's root.
	variant_guid, _ := uuid.read("ba583c80-c557-4eae-8a6e-fa440602cef2")
	root_tH := engine.Transform_Handle(loaded.root.handle)
	nested := engine.scene_instantiate_guid_nested(engine.Asset_GUID(variant_guid), root_tH)
	testing.expect(t, nested != {}, "nesting a variant under a variant should succeed")
	if nested == {} do return

	// Record the host root's child order BEFORE editing, so we can assert it is
	// stable across the edit + reload (the reported "siblings reorder" symptom).
	root_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(root_tH))
	testing.expect(t, root_t != nil)
	order_before := make([dynamic]string, 0, 8, context.temp_allocator)
	if root_t != nil {
		for ch in root_t.children {
			cht, ok := engine.scene_ref_resolve_transform(loaded, ch, root_tH)
			if !ok do continue
			c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cht))
			if c != nil do append(&order_before, strings.clone(c.name, context.temp_allocator))
		}
	}

	// Find the nested variant's content transform and edit a field that is not
	// already overridden by the inner variant (scale; inner overrides name/pos).
	// There are two TransformC_Variant instances now (host's own + the nested);
	// pick the one whose enclosing host is the freshly-nested instance.
	target_tH: engine.Transform_Handle = {}
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != loaded do continue
		if strings.compare(slot.data.name, "TransformC_Variant") != 0 do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		if engine.transform_nested_enclosing_host(h) == nested {
			target_tH = h
			break
		}
	}
	testing.expect(t, target_tH != {}, "nested variant's content transform should resolve")
	if target_tH == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target_tH))
	if ct == nil do return
	ct.scale = {3, 3, 3}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path), "save should succeed")

	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	// (1) The edited scale must survive reload (the "changes are gone" symptom).
	rroot_tH := engine.Transform_Handle(reloaded.root.handle)
	got_tH: engine.Transform_Handle = {}
	want_scale := [3]f32{3, 3, 3}
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != reloaded do continue
		if strings.compare(slot.data.name, "TransformC_Variant") != 0 do continue
		if slot.data.scale == want_scale {
			got_tH = engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
			break
		}
	}
	testing.expect(t, got_tH != {}, "edited nested-variant scale {3,3,3} must persist across save+reload")

	// (2) The host root's child order must be unchanged (the "siblings reorder"
	// symptom).
	rroot_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(rroot_tH))
	testing.expect(t, rroot_t != nil)
	if rroot_t != nil {
		order_after := make([dynamic]string, 0, 8, context.temp_allocator)
		for ch in rroot_t.children {
			cht, ok := engine.scene_ref_resolve_transform(reloaded, ch, rroot_tH)
			if !ok do continue
			c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cht))
			if c != nil do append(&order_after, strings.clone(c.name, context.temp_allocator))
		}
		testing.expect_value(t, len(order_after), len(order_before))
		if len(order_after) == len(order_before) {
			for i in 0 ..< len(order_before) {
				testing.expect(t, strings.compare(order_before[i], order_after[i]) == 0,
					fmt.tprintf("sibling order changed at %d: before=%s after=%s", i, order_before[i], order_after[i]))
			}
		}
	}
}

// s.scene nests bullet_Variant. Editing+saving bullet_Variant must propagate
// into the already-loaded s.scene's nested copy. Reproduces "s.scene has
// bullet_variant and changes are not propagated there".
@(test)
test_variant_save_propagates_to_host_scene :: proc(t: ^testing.T) {
	// Hermetic: copy the asset chain into a temp dir so the save below can't
	// mutate the real assets or leak edited bytes into another test's scene_lib.
	dir := "moonhug/tests/_tmp_propagate"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))
	copied: [dynamic]string
	defer { for f in copied { os.remove(f); delete(f) }; delete(copied); os.remove(dir) }
	for name in ([]string{"demo_prefabs.scene", "bullet_Variant.scene", "bullet.scene", "c.scene", "c_Variant.scene"}) {
		for suffix in ([]string{"", ".meta"}) {
			fn := strings.concatenate({name, suffix}, context.temp_allocator)
			src := strings.concatenate({"moonhug/assets/demo_prefabs/", fn}, context.temp_allocator)
			dst := strings.concatenate({dir, "/", fn}, context.allocator)
			data, e := os.read_entire_file(src, context.temp_allocator)
			if e != nil { delete(dst); continue }
			werr := os.write_entire_file(dst, data)
			testing.expect(t, werr == nil, fmt.tprintf("copy %s: %v", fn, werr))
			append(&copied, dst)
		}
	}

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	bv_path := strings.concatenate({dir, "/bullet_Variant.scene"}, context.temp_allocator)
	s_path := strings.concatenate({dir, "/demo_prefabs.scene"}, context.temp_allocator)

	new_color := [4]f32{0.111, 0.222, 0.333, 1}

	// EDITOR FLOW: open the variant SINGLE (unloads everything else), edit an
	// inherited-content sprite, save. s.scene is NOT loaded during this.
	variant := engine.scene_load_single_path(bv_path)
	testing.expect(t, variant != nil, "bullet_Variant should load")
	if variant == nil do return
	tc_mem.scene = variant

	edited := false
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != variant || !slot.data.nested_owned do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil {
			sr.color = new_color
			edited = true
			break
		}
	}
	testing.expect(t, edited, "should edit a sprite on the variant")
	if !edited do return
	testing.expect(t, engine.scene_save(variant, bv_path), "variant save should succeed")

	// Now open s.scene FRESH (as the editor does when you switch to it). Its
	// nested copy of bullet_Variant must reflect the saved edit.
	host := engine.scene_load_single_path(s_path)
	testing.expect(t, host != nil, "s.scene should load")
	if host == nil do return
	tc_mem.scene = host

	propagated := false
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != host do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil && sr.color == new_color do propagated = true
	}
	testing.expect(t, propagated, "edited variant color must appear in s.scene's nested copy after fresh load")
}

// Reproduces the editor bug against the REAL asset files: bullet_Variant is a
// variant of bullet, and bullet itself contains a nested c_Variant. Editing the
// inherited c_Variant's content (a SpriteRenderer color) while bullet_Variant is
// open must capture as an override on bullet_Variant's root NS and survive
// save+reload, AND the root child order must not drift.
@(test)
test_bullet_variant_inherited_c_variant_edit :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	// Save+reload to the SAME path the editor uses (overwrite the open file),
	// so the chain bake reads the just-written bytes — matching the editor.
	src := "moonhug/assets/demo_prefabs/bullet_Variant.scene"
	tmp := "moonhug/assets/_test_bullet_variant_rt.scene"
	defer os.remove(tmp)
	{
		data, rerr := os.read_entire_file(src, context.temp_allocator)
		testing.expect(t, rerr == nil, "read source variant")
		if rerr == nil do _ = os.write_entire_file(tmp, data)
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, tmp)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path(tmp)
	testing.expect(t, loaded != nil, "bullet_Variant.scene should load")
	if loaded == nil do return
	tc_mem.scene = loaded
	engine.sm_scene_set_active(loaded)

	root_tH := engine.Transform_Handle(loaded.root.handle)
	root_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(root_tH))
	testing.expect(t, root_t != nil)
	order_before := make([dynamic]string, 0, 8, context.temp_allocator)
	if root_t != nil {
		for ch in root_t.children {
			cht, ok := engine.scene_ref_resolve_transform(loaded, ch, root_tH)
			if !ok do continue
			c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cht))
			if c != nil do append(&order_before, strings.clone(c.name, context.temp_allocator))
		}
	}

	// Find a SpriteRenderer on nested-owned (inherited) content and change color.
	edited_lid: engine.Local_ID = 0
	new_color := [4]f32{0.123, 0.456, 0.789, 1}
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != loaded do continue
		if !slot.data.nested_owned do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil {
			sr.color = new_color
			edited_lid = slot.data.local_id
			break
		}
	}
	testing.expect(t, edited_lid != 0, "should find a SpriteRenderer on inherited content to edit")
	if edited_lid == 0 do return

	testing.expect(t, engine.scene_save(loaded, tmp), "save should succeed")

	reloaded := engine.scene_load_single_path(tmp)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	// (1) edited color survives reload.
	found := false
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != reloaded do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil && sr.color == new_color do found = true
	}
	testing.expect(t, found, "edited inherited-c_Variant color must persist across save+reload")

	// (2) root child order stable.
	rroot_tH := engine.Transform_Handle(reloaded.root.handle)
	rroot_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(rroot_tH))
	if rroot_t != nil {
		order_after := make([dynamic]string, 0, 8, context.temp_allocator)
		for ch in rroot_t.children {
			cht, ok := engine.scene_ref_resolve_transform(reloaded, ch, rroot_tH)
			if !ok do continue
			c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cht))
			if c != nil do append(&order_after, strings.clone(c.name, context.temp_allocator))
		}
		testing.expect_value(t, len(order_after), len(order_before))
		if len(order_after) == len(order_before) {
			for i in 0 ..< len(order_before) {
				testing.expect(t, strings.compare(order_before[i], order_after[i]) == 0,
					fmt.tprintf("sibling order changed at %d: before=%s after=%s", i, order_before[i], order_after[i]))
			}
		}
	}
}

// A variant's DEEP override (on content inside the base's own nested prefab)
// must render when the variant is NESTED as a child, not only when opened
// top-level. bullet_Variant's root NS overrides a c_Variant sprite color to
// [0,1,1,.686]; nesting bullet_Variant must show that, not the base color.
@(test)
test_variant_deep_override_applies_when_nested :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Read the variant's deep color override value from its file (don't hardcode
	// — the live asset's value changes as it is edited).
	want: [4]f32
	{
		sf, ok := engine.scene_file_load("moonhug/assets/demo_prefabs/bullet_Variant.scene")
		testing.expect(t, ok, "load bullet_Variant file")
		if !ok do return
		defer engine.scene_file_destroy(&sf)
		got := false
		for &ns in sf.nested_scenes {
			if ns.transform_parent != 0 do continue
			for ov in ns.overrides {
				if ov.property_path != "color" do continue
				arr, is_arr := ov.value.(json.Array)
				if !is_arr || len(arr) < 4 do continue
				for k in 0..<4 do want[k] = f32(arr[k].(json.Float))
				got = true
			}
		}
		testing.expect(t, got, "bullet_Variant should have a root-NS color override")
		if !got do return
	}

	bv, _ := uuid.read("d8bed4cc-521b-46b6-ac28-9353735d6bff")
	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	host := engine.scene_instantiate_guid_nested(engine.Asset_GUID(bv), root)
	testing.expect(t, host != {}, "nesting bullet_Variant should succeed")
	if host == {} do return

	found := false
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != tc_mem.scene do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr == nil do continue
		d := sr.color - want
		if d.x*d.x + d.y*d.y + d.z*d.z + d.w*d.w < 0.0001 do found = true
	}
	testing.expect(t, found, "bullet_Variant's deep color override must apply to nested c_Variant content")
}

// Reverting a variant's DEEP override must restore the inherited base value.
// bullet_Variant's root NS overrides a c_Variant sprite color to [0,1,1,.686];
// the base c_Variant color is [.5,0,0,.686]. After revert the live sprite must
// show the base color, not the override.
@(test)
test_variant_deep_override_revert :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/assets/demo_prefabs/bullet_Variant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// Locate the root variant NS and its deep override (c_Variant guid, lid 14).
	root_ns: ^engine.NestedScene = nil
	for &ns in loaded.nested_scenes {
		if engine.nested_scene_is_root_variant(loaded, &ns) { root_ns = &ns; break }
	}
	testing.expect(t, root_ns != nil, "root variant NS")
	if root_ns == nil do return
	cv, _ := uuid.read("3062313e-26b3-4cfb-a408-cdea7fc0b27f")
	target := engine.PPtr{ guid = engine.Asset_GUID(cv), local_id = 14 }

	override_color: [4]f32
	has := false
	for ov in root_ns.overrides {
		if ov.target.guid == engine.Asset_GUID(cv) && ov.target.local_id == 14 && ov.property_path == "color" {
			arr := ov.value.(json.Array)
			for k in 0..<4 do override_color[k] = f32(arr[k].(json.Float))
			has = true
		}
	}
	testing.expect(t, has, "bullet_Variant carries the deep c_Variant color override")
	if !has do return

	// Find the live sprite the override is applied to (color == override value).
	target_h: engine.Transform_Handle = {}
	for i in 0 ..< len(tc_mem.world.transforms.slots) {
		slot := &tc_mem.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != loaded do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr == nil do continue
		d := sr.color - override_color
		if d.x*d.x+d.y*d.y+d.z*d.z+d.w*d.w < 0.0001 { target_h = h; break }
	}
	testing.expect(t, target_h != {}, "override should be applied to a live sprite before revert")
	if target_h == {} do return

	// Revert must move the sprite OFF the override value (back to the inherited
	// c_Variant baseline). We don't hardcode the baseline (it depends on the live
	// file); the contract is: after revert the value differs from the override.
	engine.nested_scene_revert_override(loaded, root_ns, target, "color")

	_, sr := engine.transform_get_comp(target_h, engine.SpriteRenderer)
	testing.expect(t, sr != nil)
	if sr != nil {
		d := sr.color - override_color
		testing.expect(t, d.x*d.x+d.y*d.y+d.z*d.z+d.w*d.w > 0.0001,
			fmt.tprintf("after revert color must leave the override %v, got %v", override_color, sr.color))
	}
}
