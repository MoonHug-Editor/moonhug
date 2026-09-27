package tests

// The transform tool (editor/gizmo.odin): move, rotate and scale drags
// replayed frame by frame through gizmo_tool_frame, the proc the gizmo pass
// calls (tests/common/handles_driver.odin). The camera sits at z = 10 looking
// at the origin, so a gizmo at the origin is 1.5 units long (a tenth and a
// half of the camera distance) and lies in the screen plane.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "../engine"
import "../editor"
import "../editor/handles"
import "../editor/undo"
import "moonhug:engine/gizmos"

@(private = "file")
_Tool_Saved :: struct {
	mode:  editor.Gizmo_Mode,
	space: editor.Gizmo_Space,
	pivot: editor.Gizmo_Pivot,
}

@(private = "file")
_tool_save :: proc() -> _Tool_Saved {
	return {editor.gizmo_mode, editor.gizmo_space, editor.gizmo_pivot}
}

@(private = "file")
_tool_restore :: proc(s: _Tool_Saved) {
	editor.gizmo_end_drag_if_any()
	editor.sel_scene_clear()
	editor.gizmo_mode = s.mode
	editor.gizmo_space = s.space
	editor.gizmo_pivot = s.pivot
}

@(private = "file")
_tool_body :: proc(user: rawptr) {
	editor.gizmo_tool_frame()
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
	editor.gizmo_mode = .Translate
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
	editor.gizmo_mode = .Translate
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
	editor.gizmo_mode = .Translate
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
	editor.gizmo_mode = .Translate
	editor.gizmo_space = .Local
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
	editor.gizmo_mode = .Translate
	steps := s.top
	handles_drag(handles_test_view(), {0.75, 0, 0}, {1.75, 0, 0}, _tool_body, nil)

	testing.expectf(t, _close(_pos(a), {1, 0, 0}), "A, got %v", _pos(a))
	testing.expectf(t, _close(_pos(b), {4, -2, 0}), "B moves with it, got %v", _pos(b))
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expectf(t, _close(_pos(a), {0, 0, 0}, 1e-4) && _close(_pos(b), {3, -2, 0}, 1e-4), "one step: %v %v", _pos(a), _pos(b))
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
	editor.gizmo_mode = .Rotate
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
	editor.gizmo_mode = .Rotate
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
	editor.gizmo_mode = .Rotate
	editor.gizmo_pivot = .Center
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
	editor.gizmo_mode = .Scale
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
	editor.gizmo_mode = .Scale
	v := handles_test_view()
	// 40 pixels to the right of the center cube.
	right := [3]f32{gizmos.helper_pixel_in(v, {0, 0, 0}, 40), 0, 0}
	handles_drag(v, {0, 0, 0}, right, _tool_body, nil)

	sc := _scale(obj)
	testing.expectf(t, _close(sc, {1.2, 1.2, 1.2}, 0.01), "right grows every axis, got %v", sc)
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
	editor.gizmo_mode = .Scale
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
	editor.gizmo_tool_frame()
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
	editor.gizmo_mode = .Translate
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
	editor.gizmo_mode = .Translate
	v := handles_test_view()
	handles_step(v, {3, 3, 0}, _tool_body, nil) // the gizmo on screen, the pointer elsewhere
	handles_step(v, {0.75, 0, 0}, _tool_body, nil)
	testing.expect(t, editor.scene_tools_consume_mouse(), "over the X arrow")
	handles_step(v, {3, 3, 0}, _tool_body, nil)
	testing.expect(t, !editor.scene_tools_consume_mouse(), "away from the gizmo")
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
	editor.gizmo_mode = .Translate
	v := handles_test_view()
	steps := s.top
	handles_step(v, {0.75, 0, 0}, _tool_body, nil)
	handles_step(v, {0.75, 0, 0}, _tool_body, nil, down = true, clicked = true)
	handles_step(v, {1.75, 0, 0}, _tool_body, nil, down = true)
	editor.gizmo_mode = .Picker
	handles_step(v, {1.75, 0, 0}, _tool_body, nil, down = true)
	testing.expect_value(t, s.top, steps + 1)
	testing.expect(t, !editor.scene_tools_dragging(), "the drag ended")
	handles_step(v, {1.75, 0, 0}, _tool_body, nil)
	handles_frame(v, {1.75, 0, 0})
	testing.expectf(t, _close(_pos(obj), {1, 0, 0}), "got %v", _pos(obj))
	testing.expect_value(t, s.top, steps + 1)
}
