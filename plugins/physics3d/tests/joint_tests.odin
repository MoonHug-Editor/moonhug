package physics3d_tests

// Joints (physics3d/joints.odin): a hinge swings about its axis and turns by
// its motor within its limits, a distance joint keeps its anchors apart as a
// rod or a rope, a fixed joint holds two bodies as one and breaks above its
// force, and a joint on an object with no Rigidbody does nothing.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."

// A dynamic 1x1x1 box at `pos`.
@(private = "file")
_box :: proc(name: string, pos: [3]f32) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = pos
	_, rb_raw := engine.transform_add_comp(tH, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_raw
	physics3d.type_reset_Rigidbody(rb)
	rb.enabled = true
	_, box_raw := engine.transform_add_comp(tH, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_raw
	box.enabled = true
	box.size = {1, 1, 1}
	box.density = 1
	return tH
}

@(private = "file")
_pos :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.transform_world(tH).position
}

@(private = "file")
_steps :: proc(n: int) {
	for _ in 0 ..< n do physics3d.physics_step(1.0 / 60.0)
}

@(private = "file")
_rb_ref :: proc(tH: engine.Transform_Handle) -> engine.Ref_Local {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	owned, _ := engine.transform_find_comp(t, .Rigidbody)
	return engine.Ref_Local{handle = owned.handle}
}

// The turn of `tH` about `axis` from the identity, in degrees.
@(private = "file")
_turn_about :: proc(tH: engine.Transform_Handle, axis: [3]f32) -> f32 {
	q := engine.quat_to_native(engine.transform_world(tH).rotation)
	angle := 2 * math.acos(clamp(real(q), -1, 1))
	v := [3]f32{imag(q), jmag(q), kmag(q)}
	if linalg.dot(v, axis) < 0 do angle = -angle
	if angle > math.PI do angle -= math.TAU
	if angle < -math.PI do angle += math.TAU
	return math.to_degrees(angle)
}

@(test)
test_hinge_3d_swings_and_stops_at_its_limit :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A door hinged at its left edge about Z: it swings down about it.
	door := _box("Door", {0, 0, 0})
	_, raw := engine.transform_add_comp(door, .HingeJoint)
	hinge := cast(^physics3d.HingeJoint)raw
	physics3d.type_reset_HingeJoint(hinge)
	hinge.enabled = true
	hinge.anchor = {-0.5, 0, 0}
	hinge.axis = {0, 0, 1}
	_steps(30)
	p := _pos(door)
	testing.expectf(t, p.y < -0.1, "it swings down, at %v", p)
	testing.expectf(t, abs(linalg.length(p - [3]f32{-0.5, 0, 0}) - 0.5) < 0.02 && abs(p.z) < 0.01, "about its pivot, in its plane, at %v", p)

	// Within limits it stops at 30 degrees down.
	gate := _box("Gate", {10, 0, 0})
	_, raw2 := engine.transform_add_comp(gate, .HingeJoint)
	limited := cast(^physics3d.HingeJoint)raw2
	physics3d.type_reset_HingeJoint(limited)
	limited.enabled = true
	limited.anchor = {-0.5, 0, 0}
	limited.axis = {0, 0, 1}
	limited.use_limits = true
	limited.lower_angle = -30
	limited.upper_angle = 30
	_steps(120)
	testing.expectf(t, abs(_turn_about(gate, {0, 0, 1}) + 30) < 2, "the lower limit holds it at -30 degrees, at %v", _turn_about(gate, {0, 0, 1}))
}

@(test)
test_hinge_3d_motor_turns_its_body :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A wheel on a vertical axle through its center: gravity does not turn
	// it, the motor does, counterclockwise seen from above.
	wheel := _box("Wheel", {0, 0, 0})
	_, raw := engine.transform_add_comp(wheel, .HingeJoint)
	hinge := cast(^physics3d.HingeJoint)raw
	physics3d.type_reset_HingeJoint(hinge)
	hinge.enabled = true
	hinge.axis = {0, 1, 0}
	hinge.use_motor = true
	hinge.motor_speed = 90
	_steps(30)
	testing.expectf(t, abs(_turn_about(wheel, {0, 1, 0}) - 45) < 3, "90 degrees a second for half a second, at %v", _turn_about(wheel, {0, 1, 0}))
	testing.expectf(t, linalg.length(_pos(wheel)) < 0.01, "on its axle, at %v", _pos(wheel))
}

@(test)
test_distance_3d_rod_and_rope :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bob := _box("Bob", {1, 0, 0})
	_, raw := engine.transform_add_comp(bob, .DistanceJoint)
	rod := cast(^physics3d.DistanceJoint)raw
	physics3d.type_reset_DistanceJoint(rod)
	rod.enabled = true
	rod.connected_anchor = {1, 2, 0}
	_steps(60)
	testing.expectf(t, abs(linalg.length(_pos(bob) - [3]f32{1, 2, 0}) - 2) < 0.02, "the rod keeps 2, at %v", _pos(bob))

	load := _box("Load", {5, 0, 0})
	_, raw2 := engine.transform_add_comp(load, .DistanceJoint)
	rope := cast(^physics3d.DistanceJoint)raw2
	physics3d.type_reset_DistanceJoint(rope)
	rope.enabled = true
	rope.connected_anchor = {5, 1, 0}
	rope.auto_distance = false
	rope.distance = 3
	rope.max_distance_only = true
	_steps(120)
	testing.expectf(t, abs(_pos(load).y - (-2)) < 0.05, "the rope stops it 3 below the point, at %v", _pos(load))
}

@(test)
test_fixed_3d_holds_and_breaks :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	a := _box("A", {0, 0, 0})
	b := _box("B", {1, 0.5, 0})
	_, raw := engine.transform_add_comp(b, .FixedJoint)
	weld := cast(^physics3d.FixedJoint)raw
	weld.enabled = true
	weld.connected = _rb_ref(a)
	_steps(60)
	testing.expectf(t, _pos(a).y < -1, "they fall, at %v", _pos(a))
	testing.expectf(t, linalg.length(_pos(b) - _pos(a) - [3]f32{1, 0.5, 0}) < 0.02, "and keep their offset, %v", _pos(b) - _pos(a))

	c := _box("C", {10, 0, 0})
	_, raw2 := engine.transform_add_comp(c, .FixedJoint)
	weak := cast(^physics3d.FixedJoint)raw2
	weak.enabled = true
	weak.break_force = 1 // newtons, the box weighs about 10
	_steps(1)
	testing.expect(t, !weak.enabled, "the joint broke and its component is disabled")
	_steps(30)
	testing.expectf(t, _pos(c).y < -0.5, "the box falls free, at %v", _pos(c))
}

@(test)
test_joint_3d_needs_a_rigidbody :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	lone := engine.transform_new("Lone")
	_, raw := engine.transform_add_comp(lone, .HingeJoint)
	hinge := cast(^physics3d.HingeJoint)raw
	hinge.enabled = true
	_steps(2)
	testing.expect(t, hinge.joint == {}, "no joint without a body")
	testing.expect(t, hinge.warned, "the console says why, once")
}
