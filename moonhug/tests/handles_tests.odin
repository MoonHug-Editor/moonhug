package tests

// The scene-view handles (editor/handles): the geometry they rest on, and
// drags replayed frame by frame through the real handle procs
// (tests/common/handles_driver.odin).

import "core:math"
import "core:math/linalg"
import "core:testing"
import "../engine"
import "../engine/gizmos"
import "../editor/handles"

@(test)
test_handles_ray_plane_hits_and_misses :: proc(t: ^testing.T) {
	// Straight down onto the XZ plane from y = 10.
	ray := engine.Ray{origin = {3, 10, -2}, direction = {0, -1, 0}}
	p, ok := handles.ray_plane(ray, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, ok, "ray facing the plane hits it")
	testing.expect_value(t, p, [3]f32{3, 0, -2})

	// Parallel to the plane: no hit.
	flat := engine.Ray{origin = {0, 1, 0}, direction = {1, 0, 0}}
	_, ok2 := handles.ray_plane(flat, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, !ok2, "ray parallel to the plane misses")

	// Oblique onto the canvas plane z = 0.
	slant := engine.Ray{origin = {0, 0, 5}, direction = {1, 1, -1}}
	q, ok3 := handles.ray_plane(slant, {0, 0, 0}, {0, 0, 1})
	testing.expect(t, ok3, "oblique ray hits")
	testing.expect_value(t, q, [3]f32{5, 5, 0})
}

@(private = "file")
_near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 1e-3
}

// --- Slider ---------------------------------------------------------------------------

@(private = "file")
_Slider_Case :: struct {
	space:    matrix[4, 4]f32,
	pos, dir: [3]f32,
	started:  bool,
	last:     handles.Drag, // the last dragging or released frame
}

@(private = "file")
_slider_body :: proc(user: rawptr) {
	c := cast(^_Slider_Case)user
	gizmos.with_matrix(c.space)
	d := handles.slider(1, c.pos, c.dir)
	if d.started do c.started = true
	if d.dragging || d.released do c.last = d
}

@(test)
test_handles_slider_stays_on_its_line :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	c := _Slider_Case{space = 1, pos = {0, 0, 0}, dir = {1, 0, 0}}
	handles_drag(handles_test_view(), {0, 0, 0}, {2, 1, 0}, _slider_body, &c)
	testing.expect(t, c.started, "the press on the dot starts the drag")
	testing.expect(t, c.last.released, "the drag ends on the release frame")
	testing.expectf(t, _near(c.last.delta, {2, 0, 0}), "the move off the line is dropped, got %v", c.last.delta)
	testing.expectf(t, _near(c.last.point, {2, 0, 0}), "the point stays on the line, got %v", c.last.point)
}

@(test)
test_handles_slider_snaps_the_distance :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	c := _Slider_Case{space = 1, pos = {0, 0, 0}, dir = {1, 0, 0}}
	handles_drag(handles_test_view(), {0, 0, 0}, {1.3, 0.4, 0}, _slider_body, &c, Handles_Keys{snap = 0.5})
	testing.expectf(t, _near(c.last.delta, {1.5, 0, 0}), "1.3 snaps to 1.5, got %v", c.last.delta)
}

// Handles take points in the current gizmos space and report drags in it: a
// slider along local +X under a 90 degree turn moves along world +Y.
@(test)
test_handles_follow_the_gizmos_space :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	space := linalg.matrix4_translate_f32({5, 0, 0}) * linalg.matrix4_rotate_f32(math.PI / 2, {0, 0, 1})
	c := _Slider_Case{space = space, pos = {0, 0, 0}, dir = {1, 0, 0}}
	handles_drag(handles_test_view(), {5, 0, 0}, {5, 2, 0}, _slider_body, &c)
	testing.expect(t, c.started, "the dot sits at the space's origin in world space")
	testing.expectf(t, _near(c.last.delta, {2, 0, 0}), "the drag reports in the space, got %v", c.last.delta)
	testing.expectf(t, _near(c.last.point, {2, 0, 0}), "got %v", c.last.point)
}

// --- Bounds -----------------------------------------------------------------------------

@(private = "file")
_Bounds_Case :: struct {
	kind:           enum {Box, Sphere, Capsule},
	center, size:   [3]f32,
	radius, height: f32,
	drags:          int, // frames that reported dragging or released
}

@(private = "file")
_bounds_body :: proc(user: rawptr) {
	c := cast(^_Bounds_Case)user
	d: handles.Drag
	switch c.kind {
	case .Box:     d = handles.box_bounds(7, &c.center, &c.size)
	case .Sphere:  d = handles.sphere_bounds(7, &c.center, &c.radius)
	case .Capsule: d = handles.capsule_bounds(7, &c.center, &c.radius, &c.height, .Y)
	}
	if d.dragging || d.released do c.drags += 1
}

@(test)
test_box_bounds_face_drag :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	// The +X face moves, the -X face stays at -1.
	c := _Bounds_Case{kind = .Box, size = {2, 2, 2}}
	handles_drag(v, {1, 0, 0}, {2, 0, 0}, _bounds_body, &c)
	testing.expect_value(t, c.drags, 3)
	testing.expectf(t, _near(c.size, {3, 2, 2}) && _near(c.center, {0.5, 0, 0}), "one face: %v %v", c.size, c.center)

	// Alt: both faces move, the center stays.
	c = _Bounds_Case{kind = .Box, size = {2, 2, 2}}
	handles_drag(v, {1, 0, 0}, {2, 0, 0}, _bounds_body, &c, Handles_Keys{alt = true})
	testing.expectf(t, _near(c.size, {4, 2, 2}) && _near(c.center, {0, 0, 0}), "alt: %v %v", c.size, c.center)

	// Shift: the other axes scale by the same ratio around their centers.
	c = _Bounds_Case{kind = .Box, size = {2, 2, 2}}
	handles_drag(v, {1, 0, 0}, {2, 0, 0}, _bounds_body, &c, Handles_Keys{shift = true})
	testing.expectf(t, _near(c.size, {3, 3, 3}) && _near(c.center, {0.5, 0, 0}), "shift: %v %v", c.size, c.center)

	// Past the opposite face: the size stops at zero on that face.
	c = _Bounds_Case{kind = .Box, size = {2, 2, 2}}
	handles_drag(v, {1, 0, 0}, {-3, 0, 0}, _bounds_body, &c)
	testing.expectf(t, _near(c.size, {0, 2, 2}) && _near(c.center, {-1, 0, 0}), "clamp: %v %v", c.size, c.center)
}

@(test)
test_sphere_bounds_radius_drag :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	c := _Bounds_Case{kind = .Sphere, radius = 1}
	handles_drag(v, {1, 0, 0}, {2, 0, 0}, _bounds_body, &c)
	testing.expectf(t, abs(c.radius - 1.5) < 1e-3 && _near(c.center, {0.5, 0, 0}), "opposite side stays: %v %v", c.radius, c.center)

	c = _Bounds_Case{kind = .Sphere, radius = 1}
	handles_drag(v, {1, 0, 0}, {2, 0, 0}, _bounds_body, &c, Handles_Keys{alt = true})
	testing.expectf(t, abs(c.radius - 2) < 1e-3 && _near(c.center, {0, 0, 0}), "alt: %v %v", c.radius, c.center)
}

@(test)
test_capsule_bounds_height_and_radius :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	// The end dot on the long axis changes the height.
	c := _Bounds_Case{kind = .Capsule, radius = 0.5, height = 2}
	handles_drag(v, {0, 1, 0}, {0, 2, 0}, _bounds_body, &c)
	testing.expectf(t, abs(c.height - 3) < 1e-3 && abs(c.radius - 0.5) < 1e-3 && _near(c.center, {0, 0.5, 0}),
		"height: %v %v %v", c.height, c.radius, c.center)

	// A side dot changes the radius, and a radius past half the height
	// pushes the height out with it.
	c = _Bounds_Case{kind = .Capsule, radius = 0.5, height = 2}
	handles_drag(v, {0.5, 0, 0}, {2.5, 0, 0}, _bounds_body, &c)
	testing.expectf(t, abs(c.radius - 1.5) < 1e-3 && abs(c.height - 3) < 1e-3 && _near(c.center, {1, 0, 0}),
		"radius: %v %v %v", c.radius, c.height, c.center)
}

// --- Component handle lookup ------------------------------------------------------------

@(test)
test_comp_handle_of_finds_the_instance :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	a := engine.transform_new("A")
	cam, cam_ptr := engine.transform_add_comp(a, .Camera)
	light, light_ptr := engine.transform_add_comp(a, .Light)

	h, ok := engine.comp_handle_of(cast(^engine.CompData)cam_ptr)
	testing.expect(t, ok && h == cam.handle, "the camera's handle")
	h, ok = engine.comp_handle_of(cast(^engine.CompData)light_ptr)
	testing.expect(t, ok && h == light.handle, "the light's handle")

	stray := engine.CompData{owner = a}
	_, ok = engine.comp_handle_of(&stray)
	testing.expect(t, !ok, "a pointer that is none of the owner's components")
}

// --- Snapping ---------------------------------------------------------------------------

@(private = "file")
_Dot_Case :: struct {
	snap_off: bool,
	last:     handles.Drag,
}

@(private = "file")
_dot_body :: proc(user: rawptr) {
	c := cast(^_Dot_Case)user
	handles.with_snap(!c.snap_off)
	d := handles.dot(3, {0, 0, 0}, {0, 0, 1})
	if d.dragging || d.released do c.last = d
}

// Every handle snaps, not only sliders: a plain dot's drag snaps per axis
// while snapping is on, and with_snap(false) turns it off around a handle.
@(test)
test_handles_plane_drag_snaps_per_axis :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	c := _Dot_Case{}
	handles_drag(v, {0, 0, 0}, {1.3, 0.7, 0}, _dot_body, &c, Handles_Keys{snap = 0.5})
	testing.expectf(t, _near(c.last.delta, {1.5, 0.5, 0}), "snapped per axis, got %v", c.last.delta)
	testing.expectf(t, _near(c.last.point, {1.5, 0.5, 0}), "the point follows the snapped delta, got %v", c.last.point)

	c = _Dot_Case{snap_off = true}
	handles_drag(v, {0, 0, 0}, {1.3, 0.7, 0}, _dot_body, &c, Handles_Keys{snap = 0.5})
	testing.expectf(t, _near(c.last.delta, {1.3, 0.7, 0}), "with_snap(false) keeps the raw drag, got %v", c.last.delta)
}

@(test)
test_handles_snap_helpers :: proc(t: ^testing.T) {
	v := handles_test_view()
	handles_frame(v, {0, 0, 0}, keys = Handles_Keys{snap = 0.25, snap_angle = math.PI / 12})
	testing.expect_value(t, handles.snap(0.3), f32(0.25))
	testing.expect(t, abs(handles.snap_angle(0.3) - math.PI / 12) < 1e-6, "0.3 rad snaps to 15 degrees")
	{
		handles.with_snap(false)
		testing.expect_value(t, handles.snap(0.3), f32(0.3))
	}
	testing.expect_value(t, handles.snap(0.3), f32(0.25)) // the scope ended
	handles_frame(v, {0, 0, 0})
	testing.expect_value(t, handles.snap(0.3), f32(0.3)) // snapping off
}

// --- Picking the hot handle -----------------------------------------------------------

@(private = "file")
_Pick_Case :: struct {
	pos:     [3]f32,
	hidden:  bool, // the handle is not drawn this frame
	started: bool,
	hot:     bool,
}

@(private = "file")
_pick_body :: proc(user: rawptr) {
	c := cast(^_Pick_Case)user
	if c.hidden do return
	d := handles.dot(5, c.pos, {0, 0, 1})
	c.started = d.started
	c.hot = d.hot
}

// The hot handle comes from last frame's shapes and this frame's pointer: it
// lights and takes a click on the frame the pointer arrives.
@(test)
test_handles_hot_on_the_frame_the_pointer_arrives :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	c := _Pick_Case{pos = {1, 0, 0}}
	handles_step(v, {3, 3, 0}, _pick_body, &c) // on screen, the pointer elsewhere
	testing.expect(t, !c.hot, "not hot away from it")
	handles_step(v, {1, 0, 0}, _pick_body, &c, down = true, clicked = true)
	testing.expect(t, c.hot && c.started, "hot and grabbed on the frame the pointer arrives with a click")
	handles_step(v, {1, 0, 0}, _pick_body, &c)
	handles_frame(v, {3, 3, 0})
}

// The shapes are world space: a camera that moved since the last frame
// still finds the handle under the pointer.
@(test)
test_handles_pick_follows_a_moved_camera :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	c := _Pick_Case{pos = {1, 0, 0}}
	handles_step(handles_test_view(), {3, 3, 0}, _pick_body, &c)
	moved := handles_test_view({4, 2, 8})
	handles_step(moved, {1, 0, 0}, _pick_body, &c)
	testing.expect(t, c.hot, "hot under the pointer in the new view")
	handles_frame(moved, {3, 3, 0})
}

// A hot handle that does not call in this frame (its object was deselected)
// does not hold the pointer.
@(test)
test_handles_vanished_handle_does_not_block :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()

	c := _Pick_Case{pos = {1, 0, 0}}
	handles_step(v, {3, 3, 0}, _pick_body, &c)
	c.hidden = true
	handles_step(v, {1, 0, 0}, _pick_body, &c)
	testing.expect(t, !handles.consumes_mouse(), "nothing under the pointer calls in")
	handles_frame(v, {3, 3, 0})
}
