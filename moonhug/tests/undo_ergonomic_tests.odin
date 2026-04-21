package tests

import "../engine"
import "../editor/undo"

import "core:testing"

@(test)
test_undo_edit_transform_begin_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {10, 20, 30}
		undo.edit_end(&e)
	}

	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
	testing.expect(t, undo.can_undo(s), "undo recorded")

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
}

@(test)
test_undo_edit_transform_string_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("Before")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.name, typeid_of(string))
		delete(tr.name)
		tr.name = "After"
		undo.edit_end(&e)
	}

	testing.expect_value(t, tr.name, "After")

	undo.apply_undo(s)
	testing.expect_value(t, tr.name, "Before")

	undo.apply_redo(s)
	testing.expect_value(t, tr.name, "After")
}

@(test)
test_undo_edit_component_begin_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	if sr == nil do return

	{
		e := undo.edit_begin(owned.handle, &sr.color, typeid_of([4]f32))
		sr.color = {1, 0.5, 0.25, 1}
		undo.edit_end(&e)
	}

	testing.expect_value(t, sr.color, [4]f32{1, 0.5, 0.25, 1})

	undo.apply_undo(s)
	testing.expect_value(t, sr.color, [4]f32{1, 1, 1, 1})

	undo.apply_redo(s)
	testing.expect_value(t, sr.color, [4]f32{1, 0.5, 0.25, 1})
}

@(test)
test_undo_edit_cancel_no_record :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {5, 5, 5}
		undo.edit_cancel(&e)
	}

	testing.expect_value(t, tr.position, [3]f32{5, 5, 5})
	testing.expect(t, !undo.can_undo(s), "cancel did not record")
}

@(test)
test_undo_group_scope_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		g := undo.group_begin("Edit Pos+Scale")
		defer undo.group_end(&g)

		e1 := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {1, 1, 1}
		undo.edit_end(&e1)

		e2 := undo.edit_begin(tH, &tr.scale, typeid_of([3]f32))
		tr.scale = {2, 2, 2}
		undo.edit_end(&e2)

		undo.group_commit(&g)
	}

	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
}

@(test)
test_undo_group_scope_auto_abort :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		g := undo.group_begin("Aborted")
		defer undo.group_end(&g)

		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {7, 7, 7}
		undo.edit_end(&e)
	}

	testing.expect(t, !undo.can_undo(s), "missing group_commit aborts group")
}

@(test)
test_undo_record_delete_fused :: proc(t: ^testing.T) {
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

	undo.record_delete(childH)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(p.children), 1)

	restored_h, rok := undo.scene_find_transform_by_local_id(tc_mem.scene, child_lid)
	testing.expect(t, rok, "restored child found")
	restored := engine.pool_get(&tc_mem.world.transforms, restored_h)
	if restored == nil do return
	testing.expect_value(t, restored.position, [3]f32{7, 8, 9})

	undo.apply_redo(s)
	testing.expect_value(t, len(p.children), 0)
}

@(test)
test_undo_record_remove_component_fused :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	if sr == nil do return
	sr.color = {0.1, 0.2, 0.3, 1}

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo.record_remove_component(tH, owned.handle)
	testing.expect_value(t, len(tr.components), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(tr.components), 1)
	_, restored := engine.transform_get_comp(tH, engine.SpriteRenderer)
	testing.expect(t, restored != nil, "component restored")
	if restored == nil do return
	testing.expect_value(t, restored.color, [4]f32{0.1, 0.2, 0.3, 1})

	undo.apply_redo(s)
	testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_undo_record_create_child_and_reparent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	aH := undo.record_create_child("A", rootH)
	bH := undo.record_create_child("B", rootH)
	testing.expect(t, aH != {}, "A created")
	testing.expect(t, bH != {}, "B created")

	undo.record_reparent_to(aH, bH)
	ta := engine.pool_get(&tc_mem.world.transforms, engine.Handle(aH))
	if ta == nil do return
	testing.expect_value(t, ta.parent.handle, engine.Handle(bH))

	undo.apply_undo(s)
	testing.expect_value(t, ta.parent.handle, engine.Handle(rootH))
}

@(test)
test_undo_field_drag_external :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	d := undo.field_drag_begin(tH, &tr.position, typeid_of([3]f32), "Viewport Move")
	tr.position = {1, 0, 0}
	tr.position = {2, 0, 0}
	tr.position = {3, 0, 0}
	undo.field_drag_end(&d)

	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})
}
