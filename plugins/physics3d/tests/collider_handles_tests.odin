package physics3d_tests

// Collider bounds handles (physics3d_editor): a drag replayed through the real
// @(on_scene_handles) proc resizes the collider in its scaled space, writes
// the unscaled fields, and records one undo step.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import common "moonhug:tests/common"
import physics3d ".."
import physics3d_editor "../editor"

@(private = "file")
_box_body :: proc(user: rawptr) {
	c := cast(^physics3d.BoxCollider)user
	physics3d_editor.box_collider_handles(c, handles.Gizmo_Context{state = {.Selected, .Active, .In_Selection}, tool = .Handles})
}

@(test)
box_collider_handles_resize_in_scaled_space :: proc(t: ^testing.T) {
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

	// Width 1 at x scale 2: the +X face sits at world x = 1.
	box_t := engine.transform_new("Box")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(box_t))
	bt.scale = {2, 1, 1}
	_, box_ptr := engine.transform_add_comp(box_t, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {1, 1, 1}
	testing.expect_value(t, engine.transform_world(box_t).scale, [3]f32{2, 1, 1})

	steps := s.top
	common.handles_drag(common.handles_test_view(), {1, 0, 0}, {2, 0, 0}, _box_body, box)

	// World width 3, center 0.5: the fields hold them over the x scale. The
	// axes the drag did not touch keep their exact values.
	testing.expectf(t, linalg.length(box.size - [3]f32{1.5, 1, 1}) < 1e-3, "size %v", box.size)
	testing.expectf(t, linalg.length(box.center - [3]f32{0.25, 0, 0}) < 1e-3, "center %v", box.center)
	testing.expect_value(t, box.size.y, 1)
	testing.expect_value(t, s.top, steps + 1)

	undo.apply_undo(s)
	testing.expect_value(t, box.size, [3]f32{1, 1, 1})
	testing.expect_value(t, box.center, [3]f32{0, 0, 0})
}

// Other tools leave the collider alone: its handles show in the Handles tool
// (T) only.
@(test)
box_collider_handles_only_in_handles_tool :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	box_t := engine.transform_new("Box")
	_, box_ptr := engine.transform_add_comp(box_t, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {2, 2, 2}

	body :: proc(user: rawptr) {
		c := cast(^physics3d.BoxCollider)user
		physics3d_editor.box_collider_handles(c, handles.Gizmo_Context{state = {.Selected}, tool = .Translate})
	}
	common.handles_drag(common.handles_test_view(), {1, 0, 0}, {2, 0, 0}, body, box)
	testing.expect_value(t, box.size, [3]f32{2, 2, 2})
	testing.expect(t, !handles.consumes_mouse(), "no handle took the pointer")
}
