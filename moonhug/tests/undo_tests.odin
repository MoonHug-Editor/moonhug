package tests

import "../engine"
import undo_pkg "../editor/undo"

import "core:testing"

@(private)
_undo_pointer_types_registered: bool

@(private)
setup_undo :: proc(tc: ^TestCtx) -> ^undo_pkg.Undo_Stack {
	setup(tc, "")
	context.user_ptr = &tc.uc
	if !_undo_pointer_types_registered {
		engine.register_pointer_type(bool)
		engine.register_pointer_type(int)
		engine.register_pointer_type(i32)
		engine.register_pointer_type(u32)
		engine.register_pointer_type(f32)
		engine.register_pointer_type(string)
		_undo_pointer_types_registered = true
	}

	s := new(undo_pkg.Undo_Stack)
	undo_pkg.init(s)
	undo_pkg.install(s)
	return s
}

@(private)
teardown_undo :: proc(tc: ^TestCtx, s: ^undo_pkg.Undo_Stack) {
	undo_pkg.clear(s)
	free(s)
	teardown(tc)
}

@(test)
test_undo_value_transform_position :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	testing.expect(t, tr != nil, "transform exists")
	if tr == nil do return

	target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {10, 20, 30}
	new_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
	undo_pkg.push_value(s, target, old_json, new_json)

	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
	testing.expect(t, undo_pkg.can_undo(s), "should be able to undo")

	ok := undo_pkg.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect(t, undo_pkg.can_redo(s), "should be able to redo")

	ok = undo_pkg.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
}

@(test)
test_undo_value_component_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "sprite renderer exists")
	if sr == nil do return

	target := undo_pkg.make_component_target(owned.handle, offset_of(engine.SpriteRenderer, color), typeid_of([4]f32))
	old_json := undo_pkg.capture_json(&sr.color, typeid_of([4]f32))
	sr.color = {1, 0.5, 0.25, 1}
	new_json := undo_pkg.capture_json(&sr.color, typeid_of([4]f32))
	undo_pkg.push_value(s, target, old_json, new_json)

	ok := undo_pkg.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, sr.color, [4]f32{1, 1, 1, 1})

	ok = undo_pkg.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, sr.color, [4]f32{1, 0.5, 0.25, 1})
}

@(test)
test_undo_value_string_name :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("Before")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, name), typeid_of(string))
	old_json := undo_pkg.capture_json(&tr.name, typeid_of(string))
	delete(tr.name)
	tr.name = "After"
	new_json := undo_pkg.capture_json(&tr.name, typeid_of(string))
	undo_pkg.push_value(s, target, old_json, new_json)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, tr.name, "Before")
	undo_pkg.apply_redo(s)
	testing.expect_value(t, tr.name, "After")
}

@(test)
test_undo_reparent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	aH := engine.transform_new("A")
	bH := engine.transform_new("B")
	cH := engine.transform_new("C", aH)

	old_parent := aH
	old_index := engine.transform_get_sibling_index(cH)
	engine.transform_set_parent(cH, bH)
	new_index := engine.transform_get_sibling_index(cH)
	undo_pkg.record_reparent(cH, old_parent, bH, old_index, new_index)

	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cH))
	testing.expect(t, ct != nil, "C exists after reparent")
	if ct == nil do return
	testing.expect_value(t, ct.parent.handle, engine.Handle(bH))

	undo_pkg.apply_undo(s)
	testing.expect_value(t, ct.parent.handle, engine.Handle(aH))

	undo_pkg.apply_redo(s)
	testing.expect_value(t, ct.parent.handle, engine.Handle(bH))
}

@(test)
test_undo_create_subtree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	parentH := engine.Transform_Handle(tc_mem.scene.root.handle)

	newH := engine.transform_new("New", parentH)
	undo_pkg.record_create(newH, parentH)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 1)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, len(p.children), 0)
	testing.expect(t, !engine.pool_valid(&tc_mem.world.transforms, engine.Handle(newH)), "new should be destroyed on undo")

	undo_pkg.apply_redo(s)
	testing.expect_value(t, len(p.children), 1)
}

@(test)
test_undo_delete_subtree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	parentH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", parentH)
	ch := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	if ch == nil do return
	child_lid := ch.local_id
	ch.position = {7, 8, 9}

	pre, ok := undo_pkg.record_delete_pre(childH)
	testing.expect(t, ok, "delete_pre captured")
	engine.transform_destroy(childH)
	undo_pkg.record_delete_commit(pre)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 0)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, len(p.children), 1)

	restored_h, rok := undo_pkg.scene_find_transform_by_local_id(tc_mem.scene, child_lid)
	testing.expect(t, rok, "restored child found by local_id")
	restored := engine.pool_get(&tc_mem.world.transforms, restored_h)
	testing.expect(t, restored != nil, "restored transform exists")
	if restored == nil do return
	testing.expect_value(t, restored.name, "Child")
	testing.expect_value(t, restored.position, [3]f32{7, 8, 9})

	undo_pkg.apply_redo(s)
	testing.expect_value(t, len(p.children), 0)
}

@(test)
test_undo_add_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, sr := engine.transform_add_comp(tH, .SpriteRenderer)
	testing.expect(t, sr != nil, "sprite renderer added")
	if sr == nil do return
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo_pkg.record_add_component(tH, owned.handle, len(tr.components) - 1)

	testing.expect_value(t, len(tr.components), 1)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, len(tr.components), 0)

	undo_pkg.apply_redo(s)
	testing.expect_value(t, len(tr.components), 1)
	testing.expect(t, tr.components[0].handle.type_key == .SpriteRenderer, "component is sprite renderer")
}

@(test)
test_undo_remove_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	if sr == nil do return
	sr.color = {0.1, 0.2, 0.3, 1}
	sr.enabled = true

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	list_idx := 0

	pre, ok := undo_pkg.record_remove_component_pre(tH, owned.handle, list_idx)
	testing.expect(t, ok, "pre captured")
	engine.transform_remove_comp(tH, owned.handle)
	undo_pkg.record_remove_component_commit(pre)

	testing.expect_value(t, len(tr.components), 0)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, len(tr.components), 1)

	_, restored := engine.transform_get_comp(tH, engine.SpriteRenderer)
	testing.expect(t, restored != nil, "component restored")
	if restored == nil do return
	testing.expect_value(t, restored.color, [4]f32{0.1, 0.2, 0.3, 1})

	undo_pkg.apply_redo(s)
	testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_undo_reorder_components :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	engine.transform_add_comp(tH, .SpriteRenderer)
	engine.transform_add_comp(tH, .Camera)

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.SpriteRenderer)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Camera)

	entry := tr.components[0]
	ordered_remove(&tr.components, 0)
	inject_at(&tr.components, 1, entry)
	undo_pkg.record_reorder_components(tH, 0, 1)

	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Camera)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.SpriteRenderer)

	undo_pkg.apply_undo(s)
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.SpriteRenderer)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Camera)

	undo_pkg.apply_redo(s)
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Camera)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.SpriteRenderer)
}

@(test)
test_undo_transaction_group :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo_pkg.begin_transaction(s, "Edit Pos+Scale")
	{
		target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
		old_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
		tr.position = {1, 1, 1}
		new_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
		undo_pkg.push_value(s, target, old_json, new_json)

		target2 := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, scale), typeid_of([3]f32))
		old_json2 := undo_pkg.capture_json(&tr.scale, typeid_of([3]f32))
		tr.scale = {2, 2, 2}
		new_json2 := undo_pkg.capture_json(&tr.scale, typeid_of([3]f32))
		undo_pkg.push_value(s, target2, old_json2, new_json2)
	}
	undo_pkg.end_transaction(s, "Edit Pos+Scale")

	testing.expect(t, undo_pkg.can_undo(s), "one undo entry available")

	undo_pkg.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})

	undo_pkg.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
}

@(test)
test_undo_stack_clear :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {5, 5, 5}
	new_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
	undo_pkg.push_value(s, target, old_json, new_json)

	testing.expect(t, undo_pkg.can_undo(s), "can undo")

	undo_pkg.clear(s)
	testing.expect(t, !undo_pkg.can_undo(s), "cannot undo after clear")
	testing.expect(t, !undo_pkg.can_redo(s), "cannot redo after clear")
}

@(test)
test_undo_inspector_flow_f32_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, p := engine.transform_get_or_add_comp(tH, engine.Player)
	if p == nil do return
	p.speed = 55

	undo_pkg.push_component_owner(owned.handle)
	defer undo_pkg.pop_owner()

	undo_pkg.begin_field(&p.speed, typeid_of(f32))
	p.speed = 123
	undo_pkg.end_field(true)

	testing.expect(t, undo_pkg.can_undo(s), "should have recorded f32 change")
	testing.expect_value(t, p.speed, f32(123))

	ok := undo_pkg.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, p.speed, f32(55))

	ok = undo_pkg.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, p.speed, f32(123))
}

@(test)
test_undo_drag_sequence_commits_on_release :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, p := engine.transform_get_or_add_comp(tH, engine.Player)
	if p == nil do return
	p.speed = 55

	undo_pkg.push_component_owner(owned.handle)
	defer undo_pkg.pop_owner()

	undo_pkg.begin_field(&p.speed, typeid_of(f32))
	undo_pkg.promote_to_pending()
	undo_pkg.end_field(false)

	undo_pkg.begin_field(&p.speed, typeid_of(f32))
	p.speed = 77
	undo_pkg.end_field(false)

	undo_pkg.begin_field(&p.speed, typeid_of(f32))
	p.speed = 99
	undo_pkg.end_field(false)

	testing.expect(t, !undo_pkg.can_undo(s), "no undo until release")

	undo_pkg.begin_field(&p.speed, typeid_of(f32))
	testing.expect(t, undo_pkg.pending_matches(&p.speed), "pending tracks the field across frames")
	undo_pkg.pending_commit()
	undo_pkg.end_field(false)

	testing.expect(t, undo_pkg.can_undo(s), "commit recorded on release")
	testing.expect_value(t, p.speed, f32(99))

	undo_pkg.apply_undo(s)
	testing.expect_value(t, p.speed, f32(55))

	undo_pkg.apply_redo(s)
	testing.expect_value(t, p.speed, f32(99))
}

@(test)
test_undo_new_edit_truncates_redo :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	push_edit :: proc(s: ^undo_pkg.Undo_Stack, tr: ^engine.Transform, target: undo_pkg.Property_Target, v: [3]f32) {
		old_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
		tr.position = v
		new_json := undo_pkg.capture_json(&tr.position, typeid_of([3]f32))
		undo_pkg.push_value(s, target, old_json, new_json)
	}

	push_edit(s, tr, target, {1, 0, 0})
	push_edit(s, tr, target, {2, 0, 0})
	undo_pkg.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 0, 0})
	testing.expect(t, undo_pkg.can_redo(s), "can redo")

	push_edit(s, tr, target, {9, 9, 9})
	testing.expect(t, !undo_pkg.can_redo(s), "redo truncated by new edit")
}
