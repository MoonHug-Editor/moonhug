package physics2d_tests

// The polygon and edge colliders' point handles (physics2d_editor), replayed
// through the real @(comp_on_scene_handles) proc: a drag moves a point, a
// press on an edge inserts one and drags it, Alt+click deletes one, each as
// one undo step of the point list, in the collider's scaled space.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import common "moonhug:tests/common"
import physics2d ".."
import physics2d_editor "../editor"

@(private = "file")
_polygon_body :: proc(user: rawptr) {
	c := cast(^physics2d.PolygonCollider2D)user
	physics2d_editor.comp_on_scene_handles_PolygonCollider2D(c, handles.Gizmo_Context{state = {.Selected, .Active, .In_Selection}, tool = .Handles})
}

@(private = "file")
_edge_body :: proc(user: rawptr) {
	c := cast(^physics2d.EdgeCollider2D)user
	physics2d_editor.comp_on_scene_handles_EdgeCollider2D(c, handles.Gizmo_Context{state = {.Selected, .Active, .In_Selection}, tool = .Handles})
}

// A square of side 2 at x scale 2, with a point in the middle of its right
// side: corners at world x = ±2, y = ±1, the extra point at (2, 0).
@(private = "file")
_square :: proc(w: ^engine.World) -> ^physics2d.PolygonCollider2D {
	t := engine.transform_new("Square")
	engine.pool_get(&w.transforms, engine.Handle(t)).scale = {2, 1, 1}
	_, ptr := engine.transform_add_comp(t, .PolygonCollider2D)
	c := cast(^physics2d.PolygonCollider2D)ptr
	clear(&c.points)
	append(&c.points, [2]f32{-1, -1}, [2]f32{1, -1}, [2]f32{1, 0}, [2]f32{1, 1}, [2]f32{-1, 1})
	return c
}

// Alt+click at a world point: hover, press, release, and a frame to clear.
@(private = "file")
_alt_click :: proc(v: engine.Render_View, at: [3]f32, body: proc(user: rawptr), user: rawptr) {
	common.handles_step(v, at, body, user)
	common.handles_step(v, at, body, user, down = true, clicked = true, keys = {alt = true})
	common.handles_step(v, at, body, user, keys = {alt = true})
	common.handles_frame(v, at)
}

@(test)
polygon_handles_drag_insert_delete :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer free(s)
	defer undo.destroy(s)
	c := _square(&tc.world)
	v := common.handles_test_view()

	// Drag the corner at world (2, 1) to (3, 1): the point reads the move
	// over the x scale.
	steps := s.top
	common.handles_drag(v, {2, 1, 0}, {3, 1, 0}, _polygon_body, c)
	testing.expectf(t, linalg.length(c.points[3] - [2]f32{1.5, 1}) < 1e-3, "the corner moved to %v", c.points[3])
	testing.expect_value(t, len(c.points), 5)
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, c.points[3], [2]f32{1, 1})

	// Press the bottom edge at its middle and drag down: a sixth point, at
	// the release position, between the edge's ends.
	steps = s.top
	common.handles_drag(v, {0, -1, 0}, {0, -1.5, 0}, _polygon_body, c)
	testing.expect_value(t, len(c.points), 6)
	testing.expectf(t, linalg.length(c.points[1] - [2]f32{0, -1.5}) < 1e-3, "the new point is at %v", c.points[1])
	testing.expect_value(t, c.points[2], [2]f32{1, -1})
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, len(c.points), 5)

	// Alt+click the side point at (2, 0): one point goes, the ones after it
	// keep their place, one step. The next point takes the deleted one's
	// handle id, so a click that is not swallowed would delete it too.
	steps = s.top
	_alt_click(v, {2, 0, 0}, _polygon_body, c)
	testing.expect_value(t, len(c.points), 4)
	testing.expect_value(t, c.points[2], [2]f32{1, 1})
	testing.expect_value(t, c.points[3], [2]f32{-1, 1})
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, len(c.points), 5)
	testing.expect_value(t, c.points[2], [2]f32{1, 0})

	// An Alt press on an edge inserts nothing: the side point goes, then a
	// click on the same spot, now the right edge, leaves four.
	_alt_click(v, {2, 0, 0}, _polygon_body, c)
	_alt_click(v, {2, 0, 0}, _polygon_body, c)
	testing.expect_value(t, len(c.points), 4)
	// A polygon keeps three points: deletes stop there.
	_alt_click(v, {2, 1, 0}, _polygon_body, c)
	_alt_click(v, {2, -1, 0}, _polygon_body, c)
	_alt_click(v, {-2, -1, 0}, _polygon_body, c)
	testing.expect_value(t, len(c.points), 3)
}

@(test)
edge_handles_keep_two_points :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer free(s)
	defer undo.destroy(s)
	v := common.handles_test_view()

	e := engine.transform_new("Edge")
	_, ptr := engine.transform_add_comp(e, .EdgeCollider2D)
	c := cast(^physics2d.EdgeCollider2D)ptr
	clear(&c.points)
	append(&c.points, [2]f32{-2, 0}, [2]f32{2, 0})

	// An open line has no edge between its ends: a press at the middle of
	// the line inserts, a press beyond the ends finds nothing.
	common.handles_drag(v, {0, 0, 0}, {0, 1, 0}, _edge_body, c)
	testing.expect_value(t, len(c.points), 3)
	testing.expectf(t, linalg.length(c.points[1] - [2]f32{0, 1}) < 1e-3, "the new point is at %v", c.points[1])

	// Delete the middle point: the end after it keeps its place. Then down
	// to two, never below.
	_alt_click(v, {0, 1, 0}, _edge_body, c)
	testing.expect_value(t, len(c.points), 2)
	testing.expect_value(t, c.points[1], [2]f32{2, 0})
	_alt_click(v, {2, 0, 0}, _edge_body, c)
	testing.expect_value(t, len(c.points), 2)
}

// Five points on an edge, Alt+click on the middle one: one point goes and
// the two after it keep their places. With dots by index the next point
// takes the deleted one's handle in the same frame, and a click that is not
// stopped there runs down the line.
@(test)
edge_handles_delete_one_of_five :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer free(s)
	defer undo.destroy(s)
	v := common.handles_test_view()

	e := engine.transform_new("Edge")
	_, ptr := engine.transform_add_comp(e, .EdgeCollider2D)
	c := cast(^physics2d.EdgeCollider2D)ptr
	clear(&c.points)
	append(&c.points, [2]f32{-2, 0}, [2]f32{-1, 1}, [2]f32{0, 0}, [2]f32{1, 1}, [2]f32{2, 0})
	steps := s.top
	_alt_click(v, {0, 0, 0}, _edge_body, c)
	testing.expect_value(t, len(c.points), 4)
	testing.expect_value(t, c.points[2], [2]f32{1, 1})
	testing.expect_value(t, c.points[3], [2]f32{2, 0})
	testing.expect_value(t, s.top, steps + 1)
}
