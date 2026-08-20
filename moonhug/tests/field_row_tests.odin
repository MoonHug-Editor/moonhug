package tests

// Field rows driven across frames (field_row_harness.odin).
//
// Each test here reproduces a bug that actually shipped and was found by hand in
// the running editor. They are written as frame SEQUENCES because that is what
// every one of those bugs had in common: the individual procs were correct, and
// the order they ran in was not.

import "../editor/inspector"
import "../editor/undo"
import "../engine"

import "core:testing"

// Merely DRAWING a picker row must not touch any object.
//
// The shipped bug: the picker's transaction was opened up front, on every frame
// the row drew. That made the edit permanently in flight, so the peer apply ran
// continuously and the active object's mesh was copied onto every selected peer.
// Selecting Avocado and DamagedHelmet together silently replaced DamagedHelmet's
// mesh and materials, with no user action at all.
@(test)
test_row_idle_frames_change_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	_, b_ptr := engine.transform_add_comp(b, .MeshFilter)
	mf_a := cast(^engine.MeshFilter)a_ptr
	mf_b := cast(^engine.MeshFilter)b_ptr

	mesh_a := engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	mesh_b := engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}
	mf_a.mesh = mesh_a
	mf_b.mesh = mesh_b

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .MeshFilter), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(_comp_handle(a, .MeshFilter))
	defer undo.pop_owner()

	before_steps := s.top
	h := Row_Harness{
		field_ptr = &mf_a.mesh,
		field_tid = typeid_of(engine.Asset_GUID),
		offset    = offset_of(engine.MeshFilter, mesh),
		label     = "mesh",
	}
	// Ten frames of the row simply being on screen.
	frames := make([dynamic]Frame, 0, 10, context.temp_allocator)
	for _ in 0 ..< 10 do append(&frames, frame_idle())
	finishes := row_replay(&h, frames[:])

	testing.expect_value(t, finishes, 0)
	testing.expect_value(t, mf_a.mesh, mesh_a)
	testing.expect_value(t, mf_b.mesh, mesh_b) // the peer is UNTOUCHED
	testing.expect_value(t, s.top, before_steps)
}

// Clicking a button inside the row (the picker's search or clear) is an imgui
// activation that says nothing about the value. Treating it as the start of an
// edit opened a transaction and copied the active object's reference onto every
// peer just for opening the picker.
@(test)
test_row_button_click_is_not_an_edit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	_, b_ptr := engine.transform_add_comp(b, .MeshFilter)
	mf_a := cast(^engine.MeshFilter)a_ptr
	mf_b := cast(^engine.MeshFilter)b_ptr
	mesh_a := engine.Asset_GUID{3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3}
	mesh_b := engine.Asset_GUID{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4}
	mf_a.mesh = mesh_a
	mf_b.mesh = mesh_b

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .MeshFilter), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(_comp_handle(a, .MeshFilter))
	defer undo.pop_owner()

	h := Row_Harness{
		field_ptr = &mf_a.mesh,
		field_tid = typeid_of(engine.Asset_GUID),
		offset    = offset_of(engine.MeshFilter, mesh),
		label     = "mesh",
	}
	row_replay(&h, {frame_idle(), frame_button_click(), frame_idle()})

	testing.expect_value(t, mf_a.mesh, mesh_a)
	testing.expect_value(t, mf_b.mesh, mesh_b)
}

// A picker's value lands from a popup — no activation, no active widget. The row
// must notice the change, propagate it, and record ONE undo step that reverts
// each object to its own previous value.
@(test)
test_row_picker_write_propagates_and_records :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	_, b_ptr := engine.transform_add_comp(b, .MeshFilter)
	mf_a := cast(^engine.MeshFilter)a_ptr
	mf_b := cast(^engine.MeshFilter)b_ptr
	mesh_a := engine.Asset_GUID{5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5}
	mesh_b := engine.Asset_GUID{6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6}
	mf_a.mesh = mesh_a
	mf_b.mesh = mesh_b

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .MeshFilter), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(_comp_handle(a, .MeshFilter))
	defer undo.pop_owner()

	h := Row_Harness{
		field_ptr = &mf_a.mesh,
		field_tid = typeid_of(engine.Asset_GUID),
		offset    = offset_of(engine.MeshFilter, mesh),
		label     = "mesh",
	}
	pick :: proc(p: rawptr) {
		(cast(^engine.Asset_GUID)p)^ = engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	}
	row_replay(&h, {frame_idle(), frame_popup_write(pick), frame_idle()})

	picked := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	testing.expect_value(t, mf_a.mesh, picked)
	testing.expect_value(t, mf_b.mesh, picked)

	// One undo returns EACH object to its own value, not the active object's.
	undo.apply_undo(s)
	testing.expect_value(t, mf_a.mesh, mesh_a)
	testing.expect_value(t, mf_b.mesh, mesh_b)
}

// A SINGLE selected object's picker change must still record an undo step. The
// shipped bug scoped the before-snapshot to "has peers", so a lone object's mesh
// assignment had nothing to record against and produced no undo step at all.
@(test)
test_row_picker_single_object_records :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	mf := cast(^engine.MeshFilter)a_ptr
	original := engine.Asset_GUID{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}
	mf.mesh = original

	prev := inspector.multi_set_peers(nil) // no peers: single selection
	defer inspector.multi_set_peers(prev)
	undo.push_component_owner(_comp_handle(a, .MeshFilter))
	defer undo.pop_owner()

	before_steps := s.top
	h := Row_Harness{
		field_ptr = &mf.mesh,
		field_tid = typeid_of(engine.Asset_GUID),
		offset    = offset_of(engine.MeshFilter, mesh),
		label     = "mesh",
	}
	pick :: proc(p: rawptr) {
		(cast(^engine.Asset_GUID)p)^ = engine.Asset_GUID{8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8}
	}
	row_replay(&h, {frame_popup_write(pick)})

	testing.expect(t, s.top > before_steps, "a single-object picker change is recorded")
	undo.apply_undo(s)
	testing.expect_value(t, mf.mesh, original)
}

// A multi-frame DRAG of one vector axis. The peers follow live, keep their own
// values on the axes the user never touched, and the whole gesture is one undo
// step.
//
// Two shipped bugs live in this sequence. The pre-edit image was recaptured
// every frame, so by the release frame it already held the dragged value and the
// fieldwise diff came back empty — writing the whole vector and flattening the
// selection. And the release frame reports no movement of its own, so per-frame
// "which axes moved" logic found nothing to apply.
@(test)
test_row_vector_drag_is_fieldwise_and_one_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.scale = {1, 1, 1}
	tb.scale = {7, 7, 7} // distinct on every axis

	sel := []engine.Transform_Handle{a, b}
	prev := row_set_peers(a, sel)
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	before_steps := s.top
	h := Row_Harness{
		field_ptr = &ta.scale,
		field_tid = typeid_of([3]f32),
		offset    = offset_of(engine.Transform, scale),
		label     = "scale",
	}
	// Y moves over three frames, then the pointer stops and releases.
	drag_y1 :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 3 }
	drag_y2 :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 4 }
	drag_y3 :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 5 }
	row_replay(&h, {
		frame_press(drag_y1),
		frame_drag(drag_y2),
		frame_drag(drag_y3),
		frame_release(),
	})

	// Y took the edited value on BOTH; X and Z kept each object's own.
	testing.expect_value(t, ta.scale, [3]f32{1, 5, 1})
	testing.expect_value(t, tb.scale, [3]f32{7, 5, 7})

	// One undo step for the whole drag, reverting both objects.
	testing.expect_value(t, s.top, before_steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, ta.scale, [3]f32{1, 1, 1})
	testing.expect_value(t, tb.scale, [3]f32{7, 7, 7})
}

// A drag that ends where it started records nothing: clicking into a field and
// releasing without moving should not fill the undo stack.
@(test)
test_row_drag_without_movement_records_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.position = {1, 2, 3}
	tb.position = {4, 5, 6}

	sel := []engine.Transform_Handle{a, b}
	prev := row_set_peers(a, sel)
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	before_steps := s.top
	h := Row_Harness{
		field_ptr = &ta.position,
		field_tid = typeid_of([3]f32),
		offset    = offset_of(engine.Transform, position),
		label     = "position",
	}
	row_replay(&h, {frame_press(), frame_drag(), frame_release()})

	testing.expect_value(t, s.top, before_steps)
	testing.expect_value(t, ta.position, [3]f32{1, 2, 3})
	testing.expect_value(t, tb.position, [3]f32{4, 5, 6}) // peer never written
}

// A gesture abandoned mid-drag (panel closed, selection changed) still records
// what the user produced — the values are already written, so they must stay
// undoable rather than becoming an unrevertable change.
@(test)
test_row_abandoned_drag_still_records :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.position = {0, 0, 0}

	prev := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	before_steps := s.top
	h := Row_Harness{
		field_ptr = &ta.position,
		field_tid = typeid_of([3]f32),
		offset    = offset_of(engine.Transform, position),
		label     = "position",
	}
	move :: proc(p: rawptr) { (cast(^[3]f32)p)[0] = 9 }
	// Press, drag, and never release — row_replay closes it the way the editor's
	// per-frame sweep does.
	row_replay(&h, {frame_press(move), frame_drag()})

	testing.expect(t, s.top > before_steps, "an abandoned drag is still recorded")
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
}

// Rotation goes through the ordinary row path now: the ROW edits a per-object
// euler cache (a plain [3]f32), and the quaternion is written as a consequence.
//
// This is the property that used to need ~180 lines of bespoke machinery — its
// own mixed probe, peer-apply, moved-axes accumulator and drag tracking — all
// because the row was fighting its storage format. Turning one euler axis must
// leave each peer's other axes alone, exactly like scale.
//
// The caches are modelled here the way the wrapper lays them out: a contiguous
// block of [3]f32, one per object, so a peer is a plain field at a fixed offset.
@(test)
test_row_rotation_euler_is_fieldwise :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.rotation = engine.quat_from_euler_xyz(10, 20, 30)
	tb.rotation = engine.quat_from_euler_xyz(50, 60, 70)

	// The euler caches the row edits.
	euler_a := engine.quat_to_euler_xyz(ta.rotation)
	euler_b := engine.quat_to_euler_xyz(tb.rotation)

	// The peer points at ITS cache, and the undo target is its QUATERNION —
	// exactly the split the wrapper sets up.
	peers := []inspector.Multi_Peer{
		{base = rawptr(&euler_b), handle = engine.Handle(b), scene = tb.scene},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.rotation, typeid_of([4]f32)),
		undo.edit_target_transform(b, &tb.rotation, typeid_of([4]f32)),
	}
	prev_targets := inspector.field_edit_set_targets(targets)
	defer inspector.field_edit_set_targets(prev_targets)

	h := Row_Harness{
		field_ptr = rawptr(&euler_a),
		field_tid = typeid_of([3]f32),
		offset    = 0,
		label     = "rotation",
	}
	// The drag turns Y over two frames. The peer apply runs from the frame AFTER
	// the gesture opens, because the session captures its pre-image before the
	// drawer writes — so a one-frame press-and-release would propagate nothing.
	turn_y :: proc(p: rawptr) { (cast(^[3]f32)p)[1] = 25 }
	row_replay(&h, {frame_press(turn_y), frame_drag(turn_y), frame_release()})

	// Y took the edited value on both caches; X and Z kept their own. This is
	// the whole point: a quaternion diff would have reported all four components
	// changed and flattened the peer to the active object's orientation.
	testing.expect(t, abs(euler_a[1] - 25) < 0.01, "active Y edited")
	testing.expect(t, abs(euler_b[1] - 25) < 0.01, "peer Y took the edit")
	testing.expect(t, abs(euler_b[0] - 50) < 0.01, "peer X kept its own")
	testing.expect(t, abs(euler_b[2] - 70) < 0.01, "peer Z kept its own")
}
