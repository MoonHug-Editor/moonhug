package physics2d_tests

// Joints (physics2d/joints.odin): a hinge swings about its pivot and turns
// by its motor within its limits, a distance joint keeps its anchors apart as
// a rod or a rope, a fixed joint holds two bodies as one and breaks above its
// force, and a joint on an object with no Rigidbody2D does nothing.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."

// A dynamic 1x1 box at `pos`.
@(private = "file")
_box :: proc(name: string, pos: [2]f32) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = {pos.x, pos.y, 0}
	_, rb_raw := engine.transform_add_comp(tH, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_raw
	physics2d.type_reset_Rigidbody2D(rb)
	rb.enabled = true
	rb.use_auto_mass = true
	_, box_raw := engine.transform_add_comp(tH, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_raw
	box.enabled = true
	box.size = {1, 1}
	box.density = 1
	return tH
}

@(private = "file")
_pos :: proc(tH: engine.Transform_Handle) -> [2]f32 {
	return engine.transform_world(tH).position.xy
}

@(private = "file")
_angle :: proc(tH: engine.Transform_Handle) -> f32 {
	return engine.quat_to_euler_xyz(engine.transform_world(tH).rotation).z
}

@(private = "file")
_steps :: proc(n: int) {
	for _ in 0 ..< n do physics2d.physics_step(1.0 / 60.0)
}

// A reference to the Rigidbody2D on `tH`, as a scene load resolves one.
@(private = "file")
_rb_ref :: proc(tH: engine.Transform_Handle) -> engine.Ref_Local {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	owned, _ := engine.transform_find_comp(t, .Rigidbody2D)
	return engine.Ref_Local{handle = owned.handle}
}

@(test)
test_hinge_2d_swings_about_its_pivot :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A box held to the world by its left edge: it swings down about it.
	door := _box("Door", {0, 0})
	_, raw := engine.transform_add_comp(door, .HingeJoint2D)
	hinge := cast(^physics2d.HingeJoint2D)raw
	physics2d.type_reset_HingeJoint2D(hinge)
	hinge.enabled = true
	hinge.anchor = {-0.5, 0}
	_steps(30)
	testing.expectf(t, _pos(door).y < -0.1, "it swings down, at %v", _pos(door))
	testing.expectf(t, abs(linalg.length(_pos(door) - [2]f32{-0.5, 0}) - 0.5) < 0.02, "its center stays 0.5 from the pivot, at %v", _pos(door))

	// Within limits it stops at 30 degrees down.
	gate := _box("Gate", {10, 0})
	_, raw2 := engine.transform_add_comp(gate, .HingeJoint2D)
	limited := cast(^physics2d.HingeJoint2D)raw2
	physics2d.type_reset_HingeJoint2D(limited)
	limited.enabled = true
	limited.anchor = {-0.5, 0}
	limited.use_limits = true
	limited.lower_angle = -30
	limited.upper_angle = 30
	_steps(120)
	testing.expectf(t, abs(_angle(gate) + 30) < 2, "the lower limit holds it at -30 degrees, at %v", _angle(gate))
}

@(test)
test_hinge_2d_motor_turns_its_body :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Pivoted at its center, so gravity does not turn it: the motor does.
	wheel := _box("Wheel", {0, 0})
	_, raw := engine.transform_add_comp(wheel, .HingeJoint2D)
	hinge := cast(^physics2d.HingeJoint2D)raw
	physics2d.type_reset_HingeJoint2D(hinge)
	hinge.enabled = true
	hinge.use_motor = true
	hinge.motor_speed = 90
	_steps(30) // half a second
	testing.expectf(t, abs(_angle(wheel) - 45) < 3, "90 degrees a second for half a second, at %v", _angle(wheel))
	testing.expectf(t, linalg.length(_pos(wheel)) < 0.01, "and it stays on its pivot, at %v", _pos(wheel))

	// Game code sets the speed while the joint runs.
	hinge.motor_speed = 0
	before := _angle(wheel)
	_steps(30)
	testing.expectf(t, abs(_angle(wheel) - before) < 1, "a stopped motor holds it, %v then %v", before, _angle(wheel))
}

@(test)
test_distance_2d_rod_and_rope :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A rod from a world point 2 above the box: it keeps 2, swinging.
	bob := _box("Bob", {1, 0})
	_, raw := engine.transform_add_comp(bob, .DistanceJoint2D)
	rod := cast(^physics2d.DistanceJoint2D)raw
	physics2d.type_reset_DistanceJoint2D(rod)
	rod.enabled = true
	rod.connected_anchor = {1, 2}
	_steps(60)
	testing.expectf(t, abs(linalg.length(_pos(bob) - [2]f32{1, 2}) - 2) < 0.02, "the rod keeps 2, at %v", _pos(bob))

	// A rope of 3 from a point 1 above: the box falls until it is taut.
	load := _box("Load", {5, 0})
	_, raw2 := engine.transform_add_comp(load, .DistanceJoint2D)
	rope := cast(^physics2d.DistanceJoint2D)raw2
	physics2d.type_reset_DistanceJoint2D(rope)
	rope.enabled = true
	rope.connected_anchor = {5, 1}
	rope.auto_distance = false
	rope.distance = 3
	rope.max_distance_only = true
	_steps(120)
	testing.expectf(t, abs(_pos(load).y - (-2)) < 0.05, "the rope stops it 3 below the point, at %v", _pos(load))
}

@(test)
test_fixed_2d_holds_and_breaks :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Two boxes welded side by side fall as one.
	a := _box("A", {0, 0})
	b := _box("B", {1, 0.5})
	_, raw := engine.transform_add_comp(b, .FixedJoint2D)
	weld := cast(^physics2d.FixedJoint2D)raw
	weld.enabled = true
	weld.connected = _rb_ref(a)
	_steps(60)
	testing.expectf(t, _pos(a).y < -1, "they fall, at %v", _pos(a))
	testing.expectf(t, linalg.length(_pos(b) - _pos(a) - [2]f32{1, 0.5}) < 0.02, "and keep their offset, %v", _pos(b) - _pos(a))

	// Held to the world by a joint weaker than its weight: it breaks.
	c := _box("C", {10, 0})
	_, raw2 := engine.transform_add_comp(c, .FixedJoint2D)
	weak := cast(^physics2d.FixedJoint2D)raw2
	weak.enabled = true
	weak.break_force = 1 // newtons, the box weighs about 10
	_steps(1)
	testing.expect(t, !weak.enabled, "the joint broke and its component is disabled")
	_steps(30)
	testing.expectf(t, _pos(c).y < -0.5, "the box falls free, at %v", _pos(c))
}

@(test)
test_joint_2d_needs_a_rigidbody :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	lone := engine.transform_new("Lone")
	_, raw := engine.transform_add_comp(lone, .HingeJoint2D)
	hinge := cast(^physics2d.HingeJoint2D)raw
	hinge.enabled = true
	_steps(2)
	testing.expect(t, hinge.joint == {}, "no joint without a body")
	testing.expect(t, hinge.warned, "the console says why, once")
}
