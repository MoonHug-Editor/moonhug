package engine_tests

// The Measure tool (plugins/engine/editor/scene_tools/measure_tool.odin):
// drags replayed frame by frame through measure_tool_frame
// (tests/common/handles_driver.odin), the pointer over world points on the
// z = 0 plane, which the driver also gives as the grid point.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_tools"
import "moonhug:editor/viewport"

@(private = "file")
_measure_body :: proc(user: rawptr) {
	scene_tools.measure_tool_frame()
}

@(private = "file")
_near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 0.001
}

@(test)
test_measure_tool_measures_a_drag_in_world_units :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	prev := viewport.gizmo_mode
	defer viewport.gizmo_mode = prev
	viewport.gizmo_mode = .Measure
	v := handles_test_view()

	handles_drag(v, {0, 0, 0}, {3, 4, 0}, _measure_body, nil)
	m, ok := scene_tools.measure_result()
	if !testing.expect(t, ok, "the drag leaves a measurement") do return
	testing.expectf(t, _near(m.a, {0, 0, 0}) && _near(m.b, {3, 4, 0}), "from where it started to where it ended: %v", m)
	d, parts, pixels := scene_tools.measure_distance(m)
	testing.expectf(t, abs(d - 5) < 0.001 && !pixels, "5 world units: %v", d)
	testing.expectf(t, _near(parts, {3, 4, 0}), "3 across and 4 up: %v", parts)

	// While snapping is on, the ends snap to the move step.
	handles_drag(v, {0.2, 0.1, 0}, {2.7, 0.4, 0}, _measure_body, nil, keys = {snap = 1})
	m, _ = scene_tools.measure_result()
	testing.expectf(t, _near(m.a, {0, 0, 0}) && _near(m.b, {3, 0, 0}), "snapped ends: %v", m)

	// A click with no drag clears it.
	handles_drag(v, {1, 1, 0}, {1, 1, 0}, _measure_body, nil)
	_, ok = scene_tools.measure_result()
	testing.expect(t, !ok, "a click clears the measurement")

	// Another tool clears it too.
	handles_drag(v, {0, 0, 0}, {1, 0, 0}, _measure_body, nil)
	viewport.gizmo_mode = .Translate
	scene_tools.measure_tool_frame()
	_, ok = scene_tools.measure_result()
	testing.expect(t, !ok, "leaving the tool clears the measurement")
	testing.expect(t, !scene_tools.scene_tools_consume_mouse(), "and the left button selects again")
	viewport.gizmo_mode = .Measure
	testing.expect(t, scene_tools.scene_tools_consume_mouse(), "the Measure tool owns the left button")
}

@(test)
test_measure_tool_counts_pixels_on_a_canvas :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	prev := viewport.gizmo_mode
	defer viewport.gizmo_mode = prev
	viewport.gizmo_mode = .Measure
	prev_vp := engine.canvas_game_viewport()
	defer engine.canvas_set_game_viewport(prev_vp)
	engine.canvas_set_game_viewport({800, 600})

	// An overlay canvas: 800 by 600 units from the origin in the Scene window,
	// one unit per pixel. It counts in an orthographic view, as the 2D view
	// is: 400 by 300 units around (60, 20), looking along -Z.
	ui := engine.transform_new("Canvas", engine.Transform_Handle(tc_mem.scene.root.handle))
	engine.transform_add_comp(ui, .Canvas)
	look := linalg.matrix4_look_at_f32({60, 20, 50}, {60, 20, 0}, {0, 1, 0})
	v := engine.render_view_make(look, linalg.matrix_ortho3d_f32(-200, 200, -150, 150, 0.1, 100), 800, 600, ~u32(0))

	handles_drag(v, {10.4, 20.2, 0}, {110.6, 20.2, 0}, _measure_body, nil)
	m, ok := scene_tools.measure_result()
	if !testing.expect(t, ok, "the drag leaves a measurement") do return
	testing.expectf(t, m.canvas == ui, "both ends on the canvas: %v", m)
	d, parts, pixels := scene_tools.measure_distance(m)
	testing.expectf(t, pixels && abs(d - 101) < 0.001, "in whole pixels, 10 to 111: %v", d)
	testing.expectf(t, _near(parts, {101, 0, 0}), "all across: %v", parts)

	// An end off the canvas counts in world units.
	handles_drag(v, {10, 20, 0}, {-50, 20, 0}, _measure_body, nil)
	m, _ = scene_tools.measure_result()
	_, _, pixels = scene_tools.measure_distance(m)
	testing.expect(t, m.canvas == {} && !pixels, "off the canvas, world units")

	// Out of the canvas and back in during one drag: pixels again.
	handles_step(v, {10, 20, 0}, _measure_body, nil)
	handles_step(v, {10, 20, 0}, _measure_body, nil, down = true, clicked = true)
	handles_step(v, {-50, 20, 0}, _measure_body, nil, down = true)
	m, _ = scene_tools.measure_result()
	testing.expect(t, m.canvas == {}, "out of the canvas mid-drag, world units")
	handles_step(v, {40, 60, 0}, _measure_body, nil, down = true)
	handles_step(v, {40, 60, 0}, _measure_body, nil)
	m, _ = scene_tools.measure_result()
	d, _, pixels = scene_tools.measure_distance(m)
	testing.expectf(t, m.canvas == ui && pixels && abs(d - 50) < 0.001, "back on it, pixels again, 30 by 40: %v", d)

	// In a perspective view the overlay canvas is not there to land on.
	handles_drag(handles_test_view({60, 20, 300}), {10.4, 20.2, 0}, {110.6, 20.2, 0}, _measure_body, nil)
	m, _ = scene_tools.measure_result()
	testing.expectf(t, m.canvas == {} && _near(m.b, {110.6, 20.2, 0}), "in 3D the ends stay where the pointer is: %v", m)
}
