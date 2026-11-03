package engine_tests

// The edit the inspector opens around a container's chain on a row
// (inspector._draw_row), driven across frames like field_row_tests.odin. A
// container drawer calls nothing for undo: the provisional edit records the
// value when the drawer draws it as one widget, and drops itself when rows
// inside record their own.
//
// Each test registers its own steps and restores the generated set when it
// ends.

import "core:testing"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import "moonhug:packages/engine"
import "moonhug:registration"

// This frame's write, done by the test steps. Package-global: step procs
// cannot capture locals.
@(private = "file")
_row_write: proc(ptr: rawptr)

@(private = "file")
_row_restore_drawers :: proc() {
	inspector.drawers_reset()
	registration.register_property_drawers()
}

// Replays `frames` through _draw_row for the value at `ptr`, the way the
// field loop draws a field. The editor's frame start runs before each frame,
// with whether an item was active on the frame before.
@(private = "file")
_row_draw_replay :: proc(ptr: rawptr, tid: typeid, offset: uintptr, frames: []Frame) {
	ws: inspector.Widget_State
	inspector.field_edit_set_widget_state(&ws)
	defer inspector.field_edit_set_widget_state(nil)
	prev_active := false
	for f in frames {
		inspector.field_edit_frame_begin(prev_active)
		prev_active = f.active
		ws = inspector.Widget_State{
			activated              = f.activated,
			active                 = f.active,
			deactivated_after_edit = f.deactivated,
			held                   = f.held,
		}
		_row_write = f.write
		inspector.consume_inspector_changed()
		ctx := inspector.Ctx{ptr = ptr, tid = tid, label = "##row", offset = offset, name = "row", _row = true, _chain = inspector._chain_of(tid)}
		inspector._draw_row(&ctx)
		_row_write = nil
	}
	inspector.field_edit_frame_begin(false)
}

// A container drawn as one widget, with no edit of its own.
@(private = "file")
_step_one_widget :: proc(ctx: ^inspector.Ctx) {
	if _row_write == nil do return
	_row_write(ctx.ptr)
	inspector.mark_inspector_changed()
}

// A drawer for a vector with no edit pair: a click that changes nothing
// records nothing, a drag is one undo step that reaches the peer on the axis
// it moved.
@(test)
test_row_container_drawer_without_pair_records :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	inspector.drawers_reset()
	defer _row_restore_drawers()
	inspector.add_drawer(typeid_of([3]f32), _step_one_widget)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.scale = {1, 1, 1}
	tb.scale = {7, 7, 7}

	sel := []engine.Transform_Handle{a, b}
	prev := row_set_peers(a, sel)
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	before_steps := s.top
	offset := offset_of(engine.Transform, scale)
	_row_draw_replay(&ta.scale, typeid_of([3]f32), offset, {frame_idle(), frame_button_click(), frame_idle()})
	testing.expect_value(t, s.top, before_steps)
	testing.expect_value(t, tb.scale, [3]f32{7, 7, 7})

	drag_y1 :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 3 }
	drag_y2 :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 5 }
	_row_draw_replay(&ta.scale, typeid_of([3]f32), offset, {
		frame_press(),
		frame_drag(drag_y1),
		frame_drag(drag_y2),
		frame_release(),
	})
	testing.expect_value(t, ta.scale, [3]f32{1, 5, 1})
	testing.expect_value(t, tb.scale, [3]f32{7, 5, 7})
	testing.expect_value(t, s.top, before_steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, ta.scale, [3]f32{1, 1, 1})
	testing.expect_value(t, tb.scale, [3]f32{7, 7, 7})
}

// A step around the drawing: it continues the chain.
@(private = "file")
_step_header :: proc(ctx: ^inspector.Ctx) {
	inspector.draw(ctx)
}

// The sub-row drawer: this frame's write on the sub-row's value.
@(private = "file")
_sub_row_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if _row_write == nil do return
	_row_write(ptr)
	inspector.mark_inspector_changed()
}

// The PPtr's local id as a row of its own.
@(private = "file")
_step_sub_rows :: proc(ctx: ^inspector.Ctx) {
	p := cast(^engine.PPtr)ctx.ptr
	inspector.field_edit_row(&p.local_id, typeid_of(engine.Local_ID), ctx.offset + offset_of(engine.PPtr, local_id), "local_id", _sub_row_drawer, "##local_id")
}

// Two MeshFilters, A active and B its peer, with distinct meshes.
@(private = "file")
_row_mesh_filters :: proc() -> (mf_a, mf_b: ^engine.MeshFilter, peers: []inspector.Multi_Peer, owner: engine.Handle) {
	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	_, b_ptr := engine.transform_add_comp(b, .MeshFilter)
	mf_a = cast(^engine.MeshFilter)a_ptr
	mf_b = cast(^engine.MeshFilter)b_ptr
	mf_a.mesh = engine.PPtr{local_id = 1, guid = engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}}
	mf_b.mesh = engine.PPtr{local_id = 2, guid = engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}}
	peers = make([]inspector.Multi_Peer, 1, context.temp_allocator)
	peers[0] = inspector.Multi_Peer{base = b_ptr, handle = _comp_handle(b, .MeshFilter), scene = _scene_of(b)}
	return mf_a, mf_b, peers, _comp_handle(a, .MeshFilter)
}

// A struct whose chain continues into rows of their own: each row records its
// step, and the container's provisional edit records nothing on top.
@(test)
test_row_container_with_sub_rows_records_only_them :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	inspector.drawers_reset()
	defer _row_restore_drawers()
	inspector.add_drawer(typeid_of(engine.PPtr), _step_header, order = inspector.ORDER_OUTER)
	inspector.add_drawer(typeid_of(engine.PPtr), _step_sub_rows)

	mf_a, mf_b, peers, owner := _row_mesh_filters()
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(owner)
	defer undo.pop_owner()

	before_steps := s.top
	set_id :: proc(p: rawptr) { (cast(^engine.Local_ID)p)^ = 42 }
	_row_draw_replay(&mf_a.mesh, typeid_of(engine.PPtr), offset_of(engine.MeshFilter, mesh), {
		frame_idle(),
		frame_press(set_id),
		frame_release(),
		frame_idle(),
	})
	testing.expect_value(t, mf_a.mesh.local_id, engine.Local_ID(42))
	testing.expect_value(t, mf_b.mesh.local_id, engine.Local_ID(42))
	testing.expect_value(t, mf_b.mesh.guid, engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2})
	testing.expect_value(t, s.top, before_steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, mf_a.mesh.local_id, engine.Local_ID(1))
	testing.expect_value(t, mf_b.mesh.local_id, engine.Local_ID(2))
}

// The explicit pair around sub-rows: the sub-rows nest into it, and the
// whole drawing is one undo step.
@(private = "file")
_step_pair_sub_rows :: proc(ctx: ^inspector.Ctx) {
	row := inspector.edit_as_one_begin(ctx)
	defer inspector.edit_as_one_end(ctx, &row)
	p := cast(^engine.PPtr)ctx.ptr
	inspector.field_edit_row(&p.local_id, typeid_of(engine.Local_ID), ctx.offset + offset_of(engine.PPtr, local_id), "local_id", _pair_local_id_drawer, "##local_id")
	inspector.field_edit_row(&p.guid, typeid_of(engine.Asset_GUID), ctx.offset + offset_of(engine.PPtr, guid), "guid", _pair_guid_drawer, "##guid")
}

@(private = "file")
_pair_local_id_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if _row_write == nil do return
	(cast(^engine.Local_ID)ptr)^ = 77
	inspector.mark_inspector_changed()
}

@(private = "file")
_pair_guid_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if _row_write == nil do return
	(cast(^engine.Asset_GUID)ptr)^ = engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	inspector.mark_inspector_changed()
}

@(test)
test_row_explicit_pair_around_sub_rows_is_one_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	inspector.drawers_reset()
	defer _row_restore_drawers()
	inspector.add_drawer(typeid_of(engine.PPtr), _step_pair_sub_rows)

	mf_a, mf_b, peers, owner := _row_mesh_filters()
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(owner)
	defer undo.pop_owner()

	before_steps := s.top
	trigger :: proc(p: rawptr) {}
	_row_draw_replay(&mf_a.mesh, typeid_of(engine.PPtr), offset_of(engine.MeshFilter, mesh), {
		frame_idle(),
		frame_press(trigger),
		frame_release(),
		frame_idle(),
	})
	picked := engine.PPtr{local_id = 77, guid = engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}}
	testing.expect_value(t, mf_a.mesh, picked)
	testing.expect_value(t, mf_b.mesh, picked)
	testing.expect_value(t, s.top, before_steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, mf_a.mesh.local_id, engine.Local_ID(1))
	testing.expect_value(t, mf_b.mesh.local_id, engine.Local_ID(2))
	testing.expect_value(t, mf_b.mesh.guid, engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2})
}

// A drawer that writes this frame's value and calls nothing else: a vector's
// drag, an enum's combo pick.
@(private = "file")
_step_write_only :: proc(ctx: ^inspector.Ctx) {
	if _row_write == nil do return
	_row_write(ctx.ptr)
}

// The row raises the changed flag for its own value: a drag frame that moved
// the vector leaves it set, an idle frame leaves it clear.
@(test)
test_row_marks_changed_when_value_moved :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	inspector.drawers_reset()
	defer _row_restore_drawers()
	inspector.add_drawer(typeid_of([3]f32), _step_write_only)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.scale = {1, 1, 1}
	prev := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	offset := offset_of(engine.Transform, scale)
	drag_x :: proc(p: rawptr) { (cast(^[3]f32)p)[0] = 2 }
	_row_draw_replay(&ta.scale, typeid_of([3]f32), offset, {frame_press(), frame_drag(drag_x)})
	testing.expect_value(t, ta.scale, [3]f32{2, 1, 1})
	testing.expect(t, inspector.is_changed_flag_set(), "a frame that moved the value raises the flag")

	_row_draw_replay(&ta.scale, typeid_of([3]f32), offset, {frame_idle()})
	testing.expect(t, !inspector.is_changed_flag_set(), "an idle frame leaves the flag clear")
}

// Picking the value the enum already holds changes nothing: no flag, no undo
// step. Picking another value raises the flag and records one step.
@(test)
test_row_enum_same_pick_leaves_flag_clear :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	inspector.drawers_reset()
	defer _row_restore_drawers()
	inspector.add_drawer(typeid_of(engine.Light_Type), _step_write_only)

	a := engine.transform_new("A")
	_, raw := engine.transform_add_comp(a, .Light)
	light := cast(^engine.Light)raw
	light.type = .Point
	prev := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(_comp_handle(a, .Light))
	defer undo.pop_owner()

	before_steps := s.top
	offset := offset_of(engine.Light, type)
	pick_point :: proc(p: rawptr) { (cast(^engine.Light_Type)p)^ = .Point }
	_row_draw_replay(&light.type, typeid_of(engine.Light_Type), offset, {frame_popup_write(pick_point)})
	testing.expect(t, !inspector.is_changed_flag_set(), "a pick of the current value raises nothing")
	testing.expect_value(t, s.top, before_steps)

	pick_spot :: proc(p: rawptr) { (cast(^engine.Light_Type)p)^ = .Spot }
	_row_draw_replay(&light.type, typeid_of(engine.Light_Type), offset, {frame_popup_write(pick_spot)})
	testing.expect_value(t, light.type, engine.Light_Type.Spot)
	testing.expect(t, inspector.is_changed_flag_set(), "a pick of another value raises the flag")
	testing.expect_value(t, s.top, before_steps + 1)
}
