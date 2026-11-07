package engine_tests

// The transform tool (plugins/engine/editor/scene_tools/gizmo.odin): move, rotate and scale drags
// replayed frame by frame through gizmo_tool_frame, the proc the gizmo pass
// calls (tests/common/handles_driver.odin). The camera sits at z = 10 looking
// at the origin, so a gizmo at the origin is 1.5 units long (a tenth and a
// half of the camera distance) and lies in the screen plane.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor"
import "moonhug:editor/handles"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import "moonhug:packages/engine/editor/scene_tools"
import "moonhug:editor/viewport"

@(private = "file")
_Tool_Saved :: struct {
	mode:  viewport.Gizmo_Mode,
	space: viewport.Gizmo_Space,
	pivot: viewport.Gizmo_Pivot,
}

@(private = "file")
_tool_save :: proc() -> _Tool_Saved {
	return {viewport.gizmo_mode, viewport.gizmo_space, viewport.gizmo_pivot}
}

@(private = "file")
_tool_restore :: proc(s: _Tool_Saved) {
	scene_tools.gizmo_end_drag_if_any()
	editor.sel_scene_clear()
	viewport.gizmo_mode = s.mode
	viewport.gizmo_space = s.space
	viewport.gizmo_pivot = s.pivot
}

@(private = "file")
_tool_body :: proc(user: rawptr) {
	scene_tools.gizmo_tool_frame()
}

@(private = "file")
_close :: proc(a, b: [3]f32, tol: f32 = 0.02) -> bool {
	return linalg.length(a - b) < tol
}

@(private = "file")
_pos :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.transform_world_position(tH)
}

@(private = "file")
_scale :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).scale
}

// World +X turned by the object's world rotation.
@(private = "file")
_turned_x :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	q := engine.quat_to_native(engine.transform_world_rotation(tH))
	return linalg.quaternion128_mul_vector3(q, [3]f32{1, 0, 0})
}

@(private = "file")
_ring_point :: proc(degrees: f32, radius: f32 = 1.5) -> [3]f32 {
	a := math.to_radians(degrees)
	return {math.cos(a) * radius, math.sin(a) * radius, 0}
}

// --- Move -----------------------------------------------------------------------------

@(test)
test_tool_move_along_an_axis :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0.5, 0}, _tool_body, nil)

	testing.expectf(t, _close(_pos(obj), {1, 0, 0}), "the X arrow moves along X only, got %v", _pos(obj))
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expectf(t, _close(_pos(obj), {0, 0, 0}, 1e-4), "undo puts it back, got %v", _pos(obj))
}

@(test)
test_tool_move_on_a_plane :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	// Inside the XY square, next to the origin.
	handles_drag(handles_test_view(), {0.15, 0.15, 0}, {1.15, 0.65, 0}, _tool_body, nil)
	testing.expectf(t, _close(_pos(obj), {1, 0.5, 0}), "the XY square moves in XY, got %v", _pos(obj))
}

@(test)
test_tool_move_snaps :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	handles_drag(handles_test_view(), {0.75, 0, 0}, {2.05, 0, 0}, _tool_body, nil, Handles_Keys{snap = 0.5})
	testing.expectf(t, _close(_pos(obj), {1.5, 0, 0}, 1e-3), "1.3 snaps to 1.5, got %v", _pos(obj))
}

// Local space: the X arrow follows the object's rotation.
@(test)
test_tool_move_in_local_axes :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	engine.transform_set_world_rotation(obj, engine.quat_from_native(linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})))
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	viewport.gizmo_space = .Local
	handles_drag(handles_test_view(), {0, 0.75, 0}, {0.5, 1.75, 0}, _tool_body, nil)
	testing.expectf(t, _close(_pos(obj), {0, 1, 0}), "the local X arrow points along world Y, got %v", _pos(obj))
}

// Every selected top-level object moves, and one undo step takes them all back.
@(test)
test_tool_move_moves_the_selection :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	engine.transform_set_world_position(b, {3, -2, 0})
	editor.sel_scene_only(b)
	editor.sel_scene_add(a) // active: the gizmo sits on A
	viewport.gizmo_mode = .Translate
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0, 0}, _tool_body, nil)

	testing.expectf(t, _close(_pos(a), {1, 0, 0}), "A, got %v", _pos(a))
	testing.expectf(t, _close(_pos(b), {4, -2, 0}), "B moves with it, got %v", _pos(b))
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4) && _close(_pos(b), {3, -2, 0}, 1e-4), "one step: %v %v", _pos(a), _pos(b))
}

// The preview drives A's position with Record off: the drag leaves A where the
// pose puts it and records nothing for it, and B moves as usual.
@(private = "file")
_driven_pos_owner: engine.Handle
@(private = "file")
_driven_pos_own: inspector.Driven_Lanes // lanes the clip leaves to the object

@(private = "file")
_driven_pos_provider :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool, own: inspector.Driven_Lanes) {
	if owner != _driven_pos_owner || field_offset != offset_of(engine.Transform, position) do return false, false, {}
	(cast(^[3]f32)out)^ = {0, 0, 0}
	return true, false, _driven_pos_own
}

// The same for one field at `_driven_field`, the scale or the rotation (asked
// as euler angles).
@(private = "file")
_driven_field: uintptr
@(private = "file")
_driven_pos_whole: bool // the position is driven in every lane as well
@(private = "file")
_driven_field_provider :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool, own: inspector.Driven_Lanes) {
	if owner != _driven_pos_owner do return false, false, {}
	// The rotation asked for as a quaternion is driven whole, as the real
	// provider answers: the lanes come from the euler form.
	if field_tid == typeid_of([4]f32) {
		if field_offset == _driven_field && _driven_field == offset_of(engine.Transform, rotation) do return true, false, {}
		return false, false, {}
	}
	if field_tid != typeid_of([3]f32) do return false, false, {}
	(cast(^[3]f32)out)^ = {0, 0, 0}
	if _driven_pos_whole && field_offset == offset_of(engine.Transform, position) do return true, false, {}
	if field_offset != _driven_field do return false, false, {}
	return true, false, _driven_pos_own
}

// The clip drives X of A's scale: the X handle does nothing, the Y handle scales Y.
@(test)
test_tool_scale_follows_the_lanes_the_clip_leaves :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	_driven_pos_owner = engine.Handle(a)
	_driven_field = offset_of(engine.Transform, scale)
	_driven_pos_own = {1, 2}
	_driven_pos_whole = true // a driven position keeps the object in Scale mode
	defer _driven_pos_whole = false
	prev_provider := inspector.driven_provider
	inspector.driven_provider = _driven_field_provider
	defer inspector.driven_provider = prev_provider

	editor.sel_scene_only(a)
	viewport.gizmo_mode = .Scale
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.5, 0, 0}, _tool_body, nil)
	testing.expectf(t, _close(_scale(a), {1, 1, 1}, 1e-4), "X is driven: the scale stays, got %v", _scale(a))
	testing.expect_value(t, s.top, steps)

	handles_drag(handles_test_view(), {0, 0.75, 0}, {0, 1.5, 0}, _tool_body, nil)
	testing.expectf(t, _close(_scale(a), {1, 1.5, 1}, 1e-3), "Y is the object's: Y scales, got %v", _scale(a))
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4), "the driven position stays, got %v", _pos(a))
	testing.expect_value(t, s.top, steps + 1)
}

// The clip drives Z of A's rotation as an euler angle: the Z ring does
// nothing. With Z left to the object the ring turns it about Z.
@(test)
test_tool_rotate_follows_the_angles_the_clip_leaves :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	_driven_pos_owner = engine.Handle(a)
	_driven_field = offset_of(engine.Transform, rotation)
	_driven_pos_own = {0, 1} // Z driven
	prev_provider := inspector.driven_provider
	inspector.driven_provider = _driven_field_provider
	defer inspector.driven_provider = prev_provider

	editor.sel_scene_only(a)
	viewport.gizmo_mode = .Rotate
	steps := s.top
	handles_drag(handles_test_view(), _ring_point(45), _ring_point(135), _tool_body, nil)
	testing.expectf(t, _close(_turned_x(a), {1, 0, 0}, 1e-3), "Z is driven: no turn, got %v", _turned_x(a))
	testing.expect_value(t, s.top, steps)

	_driven_pos_own = {2} // X and Y driven, Z the object's
	handles_drag(handles_test_view(), _ring_point(45), _ring_point(135), _tool_body, nil)
	testing.expectf(t, _close(_turned_x(a), {0, 1, 0}, 1e-3), "Z is the object's: 90 degrees about Z, got %v", _turned_x(a))
	testing.expect_value(t, s.top, steps + 1)
}

@(test)
test_tool_move_leaves_a_driven_transform :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	engine.transform_set_world_position(b, {3, -2, 0})
	_driven_pos_owner = engine.Handle(a)
	_driven_pos_own = {}
	prev_provider := inspector.driven_provider
	inspector.driven_provider = _driven_pos_provider
	defer inspector.driven_provider = prev_provider

	editor.sel_scene_only(b)
	editor.sel_scene_add(a) // active: the gizmo sits on A
	viewport.gizmo_mode = .Translate
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0, 0}, _tool_body, nil)

	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4), "A is driven and stays, got %v", _pos(a))
	testing.expectf(t, _close(_pos(b), {4, -2, 0}), "B moves, got %v", _pos(b))
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4) && _close(_pos(b), {3, -2, 0}, 1e-4), "one step for B only: %v %v", _pos(a), _pos(b))
}

// The clip drives A's X only: a drag along X leaves A, a drag along Y moves it,
// as the inspector's row lets the Y lane be edited.
@(test)
test_tool_move_follows_the_lanes_the_clip_leaves :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	_driven_pos_owner = engine.Handle(a)
	_driven_pos_own = {1, 2}
	prev_provider := inspector.driven_provider
	inspector.driven_provider = _driven_pos_provider
	defer inspector.driven_provider = prev_provider

	editor.sel_scene_only(a)
	viewport.gizmo_mode = .Translate
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0.5, 0}, _tool_body, nil)
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4), "X is driven: A stays, got %v", _pos(a))
	testing.expect_value(t, s.top, steps)

	handles_drag(handles_test_view(), {0, 0.75, 0}, {0.5, 1.75, 0}, _tool_body, nil)
	testing.expectf(t, _close(_pos(a), {0, 1, 0}), "Y is the object's: A moves along Y, got %v", _pos(a))
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4), "undo puts it back, got %v", _pos(a))
}

// A drag on an object of a prefab instance records the override of the field
// it changed, as the inspector's row does.
@(test)
test_tool_move_records_the_override_on_a_prefab_instance :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	host := find_transform_named(&tc.world, loaded, "RootC", false)
	edited := find_transform_named(&tc.world, loaded, "TransformC_Variant", true)
	if host == {} || edited == {} {
		testing.fail_now(t, "the fixture has RootC and TransformC_Variant")
	}
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(edited))
	// The variant overrides its position already: the scale is free.
	engine.transform_set_world_position(edited, {0, 0, 0})
	ct.scale = {1, 1, 1}
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, ct.local_id, "scale"), "no scale override before the drag")

	editor.sel_scene_only(edited)
	viewport.gizmo_mode = .Scale
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.5, 0, 0}, _tool_body, nil)

	testing.expectf(t, _close(_scale(edited), {1.5, 1, 1}), "X scales, got %v", _scale(edited))
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, ct.local_id, "scale"), "the drag records the scale override")
}

// --- Rotate ---------------------------------------------------------------------------

@(test)
test_tool_rotate_on_a_ring :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Rotate
	steps := s.top
	// The Z ring lies in the screen plane: 45 to 135 degrees along it.
	handles_drag(handles_test_view(), _ring_point(45), _ring_point(135), _tool_body, nil)

	testing.expectf(t, _close(_turned_x(obj), {0, 1, 0}, 1e-3), "90 degrees about Z, got %v", _turned_x(obj))
	testing.expectf(t, _close(_pos(obj), {0, 0, 0}, 1e-4), "an object at the pivot stays in place, got %v", _pos(obj))
	testing.expect_value(t, s.top, steps + 1)
}

@(test)
test_tool_rotate_snaps :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Rotate
	handles_drag(handles_test_view(), _ring_point(45), _ring_point(67), _tool_body, nil, Handles_Keys{snap = 0.5, snap_angle = math.PI / 12})
	a := math.to_radians(f32(15))
	testing.expectf(t, _close(_turned_x(obj), {math.cos(a), math.sin(a), 0}, 1e-3), "22 degrees snaps to 15, got %v", _turned_x(obj))
}

// Center pivot: the objects orbit the selection's center.
@(test)
test_tool_rotate_orbits_the_center :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	engine.transform_set_world_position(a, {-1, 0, 0})
	engine.transform_set_world_position(b, {1, 0, 0})
	editor.sel_scene_only(a)
	editor.sel_scene_add(b)
	viewport.gizmo_mode = .Rotate
	viewport.gizmo_pivot = .Center
	handles_drag(handles_test_view(), _ring_point(45), _ring_point(135), _tool_body, nil)

	testing.expectf(t, _close(_pos(a), {0, -1, 0}, 1e-3), "A orbits, got %v", _pos(a))
	testing.expectf(t, _close(_pos(b), {0, 1, 0}, 1e-3), "B orbits, got %v", _pos(b))
	testing.expectf(t, _close(_turned_x(a), {0, 1, 0}, 1e-3), "and both turn, got %v", _turned_x(a))
}

// --- Scale ----------------------------------------------------------------------------

@(test)
test_tool_scale_along_an_axis :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Scale
	steps := s.top
	// Half the handle's length further out: 1.5 times the scale.
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.5, 0, 0}, _tool_body, nil)

	sc := _scale(obj)
	testing.expectf(t, _close(sc, {1.5, 1, 1}, 1e-3), "X scales, got %v", sc)
	testing.expect_value(t, s.top, steps + 1)
}

@(test)
test_tool_scale_uniform_from_the_center :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Scale
	v := handles_test_view()
	// Half the handle's length to the right of the center cube: the factor is
	// the pointer's screen move over the handle's screen length.
	size := linalg.length(v.cam_pos) * scene_tools._GIZMO_SIZE_FACTOR
	handles_drag(v, {0, 0, 0}, {size * 0.5, 0, 0}, _tool_body, nil)

	sc := _scale(obj)
	testing.expectf(t, _close(sc, {1.5, 1.5, 1.5}, 0.01), "right grows every axis, got %v", sc)
}

@(test)
test_tool_scale_snaps :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Scale
	// A 1.387 factor snaps to 1.4 in 0.1 steps.
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.33, 0, 0}, _tool_body, nil, Handles_Keys{snap = 0.5})
	sc := _scale(obj)
	testing.expectf(t, _close(sc, {1.4, 1, 1}, 1e-3), "got %v", sc)
}

// --- Arbitration and drag lifetime -------------------------------------------------------

@(private = "file")
_Handle_Over_Gizmo :: struct {
	dot_started: bool,
}

@(private = "file")
_handle_then_tool :: proc(user: rawptr) {
	c := cast(^_Handle_Over_Gizmo)user
	// A component handle on the X arrow: the pass runs handles first.
	if handles.dot(99, {0.75, 0, 0}, {0, 0, 1}).started do c.dot_started = true
	scene_tools.gizmo_tool_frame()
}

// A component handle under the pointer takes the click over the gizmo.
@(test)
test_tool_yields_to_a_component_handle :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	c := _Handle_Over_Gizmo{}
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0, 0}, _handle_then_tool, &c)
	testing.expect(t, c.dot_started, "the handle got the drag")
	testing.expectf(t, _close(_pos(obj), {0, 0, 0}, 1e-4), "the object stays, got %v", _pos(obj))
}

// The pointer over the gizmo blocks click picking from the frame it arrives,
// and stops blocking on the frame it leaves.
@(test)
test_tool_hover_blocks_picking :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	v := handles_test_view()
	handles_step(v, {3, 3, 0}, _tool_body, nil) // the gizmo on screen, the pointer elsewhere
	handles_step(v, {0.75, 0, 0}, _tool_body, nil)
	testing.expect(t, scene_tools.scene_tools_consume_mouse(), "over the X arrow")
	handles_step(v, {3, 3, 0}, _tool_body, nil)
	testing.expect(t, !scene_tools.scene_tools_consume_mouse(), "away from the gizmo")
	handles_frame(v, {3, 3, 0})
}

// Q mid-drag hides the gizmo: the drag so far is one undo step and the object
// stays where it was dragged.
@(test)
test_tool_switch_mid_drag_closes_the_step :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	v := handles_test_view()
	steps := s.top
	handles_step(v, {0.75, 0, 0}, _tool_body, nil)
	handles_step(v, {0.75, 0, 0}, _tool_body, nil, down = true, clicked = true)
	handles_step(v, {1.75, 0, 0}, _tool_body, nil, down = true)
	viewport.gizmo_mode = .Picker
	handles_step(v, {1.75, 0, 0}, _tool_body, nil, down = true)
	testing.expect_value(t, s.top, steps + 1)
	testing.expect(t, !scene_tools.scene_tools_dragging(), "the drag ended")
	handles_step(v, {1.75, 0, 0}, _tool_body, nil)
	handles_frame(v, {1.75, 0, 0})
	testing.expectf(t, _close(_pos(obj), {1, 0, 0}), "got %v", _pos(obj))
	testing.expect_value(t, s.top, steps + 1)
}

// Escape mid-drag: every target goes back where the drag found it, the
// drag ends, and no undo step is recorded.
@(test)
test_tool_cancel_puts_the_drag_back :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	saved := _tool_save()
	defer _tool_restore(saved)

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	viewport.gizmo_mode = .Translate
	steps := s.top
	v := handles_test_view()
	handles_step(v, {0.75, 0, 0}, _tool_body, nil)
	handles_step(v, {0.75, 0, 0}, _tool_body, nil, down = true, clicked = true)
	handles_step(v, {1.75, 0.5, 0}, _tool_body, nil, down = true)
	testing.expect(t, scene_tools.gizmo_is_dragging())
	testing.expectf(t, _close(_pos(obj), {1, 0, 0}), "mid-drag the object moved, got %v", _pos(obj))

	scene_tools.gizmo_cancel_drag()
	testing.expect(t, !scene_tools.gizmo_is_dragging())
	testing.expectf(t, _close(_pos(obj), {0, 0, 0}, 1e-4), "cancel puts it back, got %v", _pos(obj))
	testing.expect_value(t, s.top, steps)
	handles_step(v, {1.75, 0.5, 0}, _tool_body, nil)
}
