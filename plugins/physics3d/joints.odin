package physics3d

// Joints: a constraint between the Rigidbody on the joint's own object and
// another body, or a point fixed in the world. The 3D sibling of
// physics2d/joints.odin, with the same rules:
//
// - `connected` names the other body, a Rigidbody. Empty holds the object to
//   the world.
// - The fixed step builds a joint once both bodies exist, from the pose they
//   have then: the anchors are where they are at that moment, and the angle
//   between the bodies then is a hinge's zero.
// - Motor, limit and spring fields reach the live joint every step, so game
//   code drives a motor by setting motor_speed. The anchors, the axis, the
//   connected body and enable_collision apply when the joint is built:
//   disabling and enabling the component builds it again.
// - break_force and break_torque, when above 0: a step whose joint force or
//   torque goes above them breaks the joint. The joint goes and the
//   component is disabled.

import "core:math"
import "core:math/linalg"
import b3 "vendor:box3d"
import "moonhug:packages/engine"
import "moonhug:libs/log"

// A hinge: the two bodies share a point and turn about an axis through it.
@(component={menu="Physics3D/HingeJoint"})
@(typ_guid={guid = "6a2d9f14-c83b-4e75-a10f-3b8e5d7c2a96"})
HingeJoint :: struct {
	using base:       engine.CompData `inspect:"-"`,
	// The other body. Empty: a point fixed in the world.
	connected:        engine.Ref_Local `ref:"Rigidbody"`,
	// The pivot, in the object's own space.
	anchor:           [3]f32,
	// The axis the bodies turn about, in the object's own space.
	axis:             [3]f32,
	// The two bodies collide with each other.
	enable_collision: bool,
	use_limits:       bool,
	// The turn allowed each way about the axis, in degrees from the angle the
	// joint was built at.
	lower_angle:      f32 `decor:range(-359, 359)`,
	upper_angle:      f32 `decor:range(-359, 359)`,
	use_motor:        bool,
	// The turn the motor aims at, in degrees per second, counterclockwise
	// seen from where the axis points.
	motor_speed:      f32,
	// The most torque the motor applies, in newton-meters.
	max_motor_torque: f32 `decor:min(0)`,
	// Newtons and newton-meters above which the joint breaks. 0 never breaks.
	break_force:      f32 `decor:min(0)`,
	break_torque:     f32 `decor:min(0)`,

	joint:  b3.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_reset_HingeJoint :: proc(j: ^HingeJoint) {
	type_cleanup_HingeJoint(j)
	j.axis = {1, 0, 0}
	j.lower_angle = -90
	j.upper_angle = 90
	j.max_motor_torque = 10000
}

// Runs on destroy, removal, Reset and undo: the joint goes with the component.
type_cleanup_HingeJoint :: proc(j: ^HingeJoint) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// Keeps two anchors at a distance: a rod, a rope, or a spring.
@(component={menu="Physics3D/DistanceJoint"})
@(typ_guid={guid = "c35e81b7-29d4-4a6f-9e0c-5f71a8b3d24e"})
DistanceJoint :: struct {
	using base:        engine.CompData `inspect:"-"`,
	// The other body. Empty: a point fixed in the world.
	connected:         engine.Ref_Local `ref:"Rigidbody"`,
	// The anchor on this object, in its own space.
	anchor:            [3]f32,
	// The anchor on the other body, in its object's own space, or in the
	// world when there is none.
	connected_anchor:  [3]f32,
	// The distance is the anchors' when the joint is built.
	auto_distance:     bool,
	distance:          f32 `decor:min(0)`,
	// A rope: the anchors may come closer, never farther apart.
	max_distance_only: bool,
	// How stiffly the distance springs back, in hertz. 0 is a rigid rod.
	spring_frequency:  f32 `decor:min(0)`,
	// How fast the spring stops swinging: 0 never, 1 without overshooting.
	damping_ratio:     f32 `decor:range(0, 1)`,
	// The two bodies collide with each other.
	enable_collision:  bool,
	// Newtons above which the joint breaks. 0 never breaks.
	break_force:       f32 `decor:min(0)`,

	joint:  b3.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_reset_DistanceJoint :: proc(j: ^DistanceJoint) {
	type_cleanup_DistanceJoint(j)
	j.auto_distance = true
	j.distance = 1
}

type_cleanup_DistanceJoint :: proc(j: ^DistanceJoint) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// Holds the two bodies together as one.
@(component={menu="Physics3D/FixedJoint"})
@(typ_guid={guid = "8f04b6d2-71ea-4c39-b85d-e2a9c6f1037b"})
FixedJoint :: struct {
	using base:       engine.CompData `inspect:"-"`,
	// The other body. Empty: the world.
	connected:        engine.Ref_Local `ref:"Rigidbody"`,
	// The two bodies collide with each other.
	enable_collision: bool,
	// Newtons and newton-meters above which the joint breaks. 0 never breaks.
	break_force:      f32 `decor:min(0)`,
	break_torque:     f32 `decor:min(0)`,

	joint:  b3.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_cleanup_FixedJoint :: proc(j: ^FixedJoint) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// The world point an anchor in `owner`'s own space is at now.
joint_anchor_world :: proc(owner: engine.Transform_Handle, anchor: [3]f32) -> [3]f32 {
	tw := engine.transform_world(owner)
	p := engine.trs_matrix(tw.position, tw.rotation, tw.scale) * [4]f32{anchor.x, anchor.y, anchor.z, 1}
	return p.xyz
}

// The world direction of an axis in `owner`'s own space, of length 1. +X
// for a zero axis.
joint_axis_world :: proc(owner: engine.Transform_Handle, axis: [3]f32) -> [3]f32 {
	tw := engine.transform_world(owner)
	d := engine.trs_matrix(tw.position, tw.rotation, tw.scale) * [4]f32{axis.x, axis.y, axis.z, 0}
	if n := linalg.normalize0(d.xyz); n != {} do return n
	return {1, 0, 0}
}

// The connected Rigidbody's object, {} for the world (an empty reference)
// or one that is gone.
joint_connected_object :: proc(connected: engine.Ref_Local) -> engine.Transform_Handle {
	if connected.handle == {} do return {}
	rb := cast(^Rigidbody)engine.world_pool_get(engine.ctx_world(), connected.handle)
	return rb != nil ? rb.owner : {}
}

// --- Sync ------------------------------------------------------------------------

// The two bodies of a joint on `owner`: `own` on the object, `other` the
// connected body or, for an empty reference, the ground body. ok=false while
// one does not exist yet. A joint on an object without a Rigidbody says so
// once.
@(private = "file")
_joint_bodies :: proc(w: ^engine.World, owner: engine.Transform_Handle, connected: engine.Ref_Local, warned: ^bool, kind: string) -> (own, other: b3.BodyId, ok: bool) {
	own, ok = body_of(owner)
	if !ok {
		if _, rb := engine.transform_get_comp(owner, Rigidbody); rb == nil && !warned^ {
			warned^ = true
			t := engine.pool_get(&w.transforms, engine.Handle(owner))
			log.warningf("[Physics3D] the %s on %q does nothing: it needs a Rigidbody on its own object", kind, t != nil ? t.name : "?")
		}
		return {}, {}, false
	}
	if connected.local_id == 0 && connected.handle == {} do return own, _ground(), true
	rb := cast(^Rigidbody)engine.world_pool_get(w, connected.handle)
	if rb == nil || !b3.Body_IsValid(rb.body) do return {}, {}, false
	return own, rb.body, true
}

// A static body at the origin, for joints that hold an object to the world.
@(private = "file")
_ground :: proc() -> b3.BodyId {
	if !b3.Body_IsValid(_state.ground) {
		def := b3.DefaultBodyDef()
		def.type = .staticBody
		_state.ground = b3.CreateBody(_state.world, def)
	}
	return _state.ground
}

// The frame `world` (a world position and rotation) in `body`'s own space.
@(private = "file")
_local_frame :: proc(body: b3.BodyId, p: [3]f32, q: b3.Quat) -> b3.Transform {
	return {p = b3.Body_GetLocalPoint(body, p), q = linalg.quaternion_inverse(b3.Body_GetRotation(body)) * q}
}

// Builds missing joints, removes those of disabled components and pushes the
// live fields. Before the world step.
//
// Body A is the connected body and body B the joint's own object: box3d's
// angle and motor are B's turn relative to A, so they are the object's own.
_sync_joints :: proc(w: ^engine.World) {
	{
		it := engine.pool_iterator(hinge_joints(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if !b3.Joint_IsValid(j.joint) {
				own, other, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "HingeJoint")
				if !ok do continue
				// The joint turns about its frames' z axes: a frame whose z
				// is the hinge axis, at the pivot.
				pivot := joint_anchor_world(j.owner, j.anchor)
				q := b3.ComputeQuatBetweenUnitVectors({0, 0, 1}, joint_axis_world(j.owner, j.axis))
				def := b3.DefaultRevoluteJointDef()
				def.bodyIdA = other
				def.bodyIdB = own
				def.localFrameA = _local_frame(other, pivot, q)
				def.localFrameB = _local_frame(own, pivot, q)
				def.collideConnected = j.enable_collision
				j.joint = b3.CreateRevoluteJoint(_state.world, def)
			}
			_push_hinge(j)
		}
	}
	{
		it := engine.pool_iterator(distance_joints(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if !b3.Joint_IsValid(j.joint) {
				own, other, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "DistanceJoint")
				if !ok do continue
				from := joint_anchor_world(j.owner, j.anchor)
				to := j.connected_anchor
				if o := joint_connected_object(j.connected); o != {} do to = joint_anchor_world(o, j.connected_anchor)
				if j.auto_distance do j.distance = linalg.length(to - from)
				def := b3.DefaultDistanceJointDef()
				def.bodyIdA = other
				def.bodyIdB = own
				def.localFrameA = _local_frame(other, to, b3.Quat(1))
				def.localFrameB = _local_frame(own, from, b3.Quat(1))
				def.length = max(j.distance, 0.005)
				def.collideConnected = j.enable_collision
				j.joint = b3.CreateDistanceJoint(_state.world, def)
			}
			_push_distance(j)
		}
	}
	{
		it := engine.pool_iterator(fixed_joints(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if b3.Joint_IsValid(j.joint) do continue
			own, other, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "FixedJoint")
			if !ok do continue
			// The weld frame: this body's own, as it is now.
			p, q := b3.Body_GetPosition(own), b3.Body_GetRotation(own)
			def := b3.DefaultWeldJointDef()
			def.bodyIdA = other
			def.bodyIdB = own
			def.localFrameA = _local_frame(other, p, q)
			def.localFrameB = _local_frame(own, p, q)
			def.collideConnected = j.enable_collision
			j.joint = b3.CreateWeldJoint(_state.world, def)
		}
	}
}

// The live fields of a hinge, set only when they differ: a change wakes the
// bodies, so a motor started on a sleeping body turns it.
@(private = "file")
_push_hinge :: proc(j: ^HingeJoint) {
	id := j.joint
	changed := false
	lo, hi := math.to_radians(min(j.lower_angle, j.upper_angle)), math.to_radians(max(j.lower_angle, j.upper_angle))
	if b3.RevoluteJoint_IsLimitEnabled(id) != j.use_limits {
		b3.RevoluteJoint_EnableLimit(id, j.use_limits)
		changed = true
	}
	if b3.RevoluteJoint_GetLowerLimit(id) != lo || b3.RevoluteJoint_GetUpperLimit(id) != hi {
		b3.RevoluteJoint_SetLimits(id, lo, hi)
		changed = true
	}
	if b3.RevoluteJoint_IsMotorEnabled(id) != j.use_motor {
		b3.RevoluteJoint_EnableMotor(id, j.use_motor)
		changed = true
	}
	speed := math.to_radians(j.motor_speed)
	if b3.RevoluteJoint_GetMotorSpeed(id) != speed {
		b3.RevoluteJoint_SetMotorSpeed(id, speed)
		changed = true
	}
	if b3.RevoluteJoint_GetMaxMotorTorque(id) != j.max_motor_torque {
		b3.RevoluteJoint_SetMaxMotorTorque(id, j.max_motor_torque)
		changed = true
	}
	if changed do b3.Joint_WakeBodies(id)
}

// A rod is the joint's rigid length. A spring springs toward it. A rope has
// no spring force and a limit of the length, so only stretching is stopped.
@(private = "file")
_push_distance :: proc(j: ^DistanceJoint) {
	id := j.joint
	changed := false
	spring := j.spring_frequency > 0 || j.max_distance_only
	if b3.DistanceJoint_IsSpringEnabled(id) != spring {
		b3.DistanceJoint_EnableSpring(id, spring)
		changed = true
	}
	if b3.DistanceJoint_GetSpringHertz(id) != j.spring_frequency {
		b3.DistanceJoint_SetSpringHertz(id, j.spring_frequency)
		changed = true
	}
	if b3.DistanceJoint_GetSpringDampingRatio(id) != j.damping_ratio {
		b3.DistanceJoint_SetSpringDampingRatio(id, j.damping_ratio)
		changed = true
	}
	length := max(j.distance, 0.005)
	if b3.DistanceJoint_GetLength(id) != length {
		b3.DistanceJoint_SetLength(id, length)
		changed = true
	}
	if b3.DistanceJoint_IsLimitEnabled(id) != j.max_distance_only {
		b3.DistanceJoint_EnableLimit(id, j.max_distance_only)
		changed = true
	}
	if j.max_distance_only && b3.DistanceJoint_GetMaxLength(id) != length {
		b3.DistanceJoint_SetLengthRange(id, 0, length)
		changed = true
	}
	if changed do b3.Joint_WakeBodies(id)
}

// Breaks the joints whose force or torque in the step went over their
// limits. After the world step.
_break_joints :: proc(w: ^engine.World) {
	check :: proc(id: ^b3.JointId, enabled: ^bool, force, torque: f32) {
		if !b3.Joint_IsValid(id^) || force <= 0 && torque <= 0 do return
		over := force > 0 && linalg.length(b3.Joint_GetConstraintForce(id^)) > force
		over ||= torque > 0 && linalg.length(b3.Joint_GetConstraintTorque(id^)) > torque
		if !over do return
		_destroy_joint(id)
		enabled^ = false
	}
	{
		it := engine.pool_iterator(hinge_joints(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, j.break_torque)
	}
	{
		it := engine.pool_iterator(distance_joints(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, 0)
	}
	{
		it := engine.pool_iterator(fixed_joints(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, j.break_torque)
	}
}

_destroy_joint :: proc(joint: ^b3.JointId) {
	if _state.world_ready && b3.Joint_IsValid(joint^) do b3.DestroyJoint(joint^, true)
	joint^ = {}
}
