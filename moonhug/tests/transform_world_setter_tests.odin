package tests

// transform_set_world_position/rotation round-trips under rotated + scaled
// parents — the math the scene-view gizmos stand on.

import "core:math"
import "core:testing"
import "../engine"

@(private = "file")
_v3_close :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

@(test)
test_set_world_position_under_rotated_scaled_parent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_world_setters.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parent := engine.transform_new("Parent")
	engine.scene_set_root(tc_mem.scene, parent)
	child := engine.transform_new("Child")
	engine.transform_set_parent(child, parent)

	w := engine.ctx_world()
	pt := engine.pool_get(&w.transforms, engine.Handle(parent))
	pt.position = {3, -2, 5}
	pt.rotation = engine.quat_from_euler_xyz(20, 45, -30)
	pt.scale = {2, 0.5, 1.5}

	target := [3]f32{-1.25, 4.5, 0.75}
	engine.transform_set_world_position(child, target)
	got := engine.transform_world_position(child)
	testing.expect(t, _v3_close(got, target), "world position should round-trip under rotated+scaled parent")

	// No parent: plain assignment.
	engine.transform_set_world_position(parent, {7, 8, 9})
	testing.expect(t, _v3_close(engine.transform_world_position(parent), {7, 8, 9}), "root world position should round-trip")
}

@(test)
test_set_world_rotation_under_rotated_parent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_world_rot_setters.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parent := engine.transform_new("Parent")
	engine.scene_set_root(tc_mem.scene, parent)
	child := engine.transform_new("Child")
	engine.transform_set_parent(child, parent)

	w := engine.ctx_world()
	pt := engine.pool_get(&w.transforms, engine.Handle(parent))
	pt.rotation = engine.quat_from_euler_xyz(0, 90, 15)

	target := engine.quat_from_euler_xyz(30, -60, 45)
	engine.transform_set_world_rotation(child, target)
	got := engine.transform_world_rotation(child)

	// Quaternions: q and -q are the same rotation — compare via |dot| ≈ 1.
	dot := got.x * target.x + got.y * target.y + got.z * target.z + got.w * target.w
	testing.expect(t, math.abs(dot) > 0.9999, "world rotation should round-trip under rotated parent")
}
