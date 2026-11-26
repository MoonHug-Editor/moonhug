package physics2d

// Joints: a constraint between the Rigidbody2D on the joint's own object and
// another body, or a point fixed in the world.
//
// - `connected` names the other body, a Rigidbody2D. Empty holds the object
//   to the world.
// - The fixed step builds a joint once both bodies exist, from the pose they
//   have then: the anchors are where they are at that moment, and the angle
//   between the bodies then is a hinge's zero.
// - Motor, limit and spring fields reach the live joint every step, so game
//   code drives a motor by setting motor_speed. The anchors, the connected
//   body and enable_collision apply when the joint is built: disabling and
//   enabling the component builds it again.
// - break_force and break_torque, when above 0: a step whose joint force or
//   torque goes above them breaks the joint. The joint goes and the
//   component is disabled.
// - A disabled joint has no live joint. Enabled again, it is built again
//   from the pose of that moment.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import b2 "vendor:box2d"
import "moonhug:packages/engine"
import "moonhug:libs/log"

// A hinge: the two bodies share a point and turn about it.
@(component={menu="Physics2D/HingeJoint2D", icon="SYNC"})
@(typ_guid={guid = "4c7f2a91-3e6b-4d58-9a1f-6b2e8c0d7f13"})
HingeJoint2D :: struct {
	using base:       engine.CompData `inspect:"-"`,
	// The other body. Empty: a point fixed in the world.
	connected:        engine.Ref_Local `ref:"Rigidbody2D"`,
	// The pivot, in the object's own space.
	anchor:           [2]f32,
	// The two bodies collide with each other.
	enable_collision: bool,
	use_limits:       bool,
	// The turn allowed each way, in degrees from the angle the joint was built at.
	lower_angle:      f32 `decor:range(-359, 359)`,
	upper_angle:      f32 `decor:range(-359, 359)`,
	use_motor:        bool,
	// The turn the motor aims at, in degrees per second, counterclockwise.
	motor_speed:      f32,
	// The most torque the motor applies, in newton-meters.
	max_motor_torque: f32 `decor:min(0)`,
	// Newtons and newton-meters above which the joint breaks. 0 never breaks.
	break_force:      f32 `decor:min(0)`,
	break_torque:     f32 `decor:min(0)`,

	joint:  b2.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_reset_HingeJoint2D :: proc(j: ^HingeJoint2D) {
	type_cleanup_HingeJoint2D(j)
	j.lower_angle = -90
	j.upper_angle = 90
	j.max_motor_torque = 10000
}

// Runs on destroy, removal, Reset and undo: the joint goes with the component.
type_cleanup_HingeJoint2D :: proc(j: ^HingeJoint2D) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// Keeps two anchors at a distance: a rod, a rope, or a spring.
@(component={menu="Physics2D/DistanceJoint2D", icon="STRAIGHTEN"})
@(typ_guid={guid = "9b3e5d27-8a41-4f6c-b2d9-1e7a0c4f5b68"})
DistanceJoint2D :: struct {
	using base:        engine.CompData `inspect:"-"`,
	// The other body. Empty: a point fixed in the world.
	connected:         engine.Ref_Local `ref:"Rigidbody2D"`,
	// The anchor on this object, in its own space.
	anchor:            [2]f32,
	// The anchor on the other body, in its object's own space, or in the
	// world when there is none.
	connected_anchor:  [2]f32,
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

	joint:  b2.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_reset_DistanceJoint2D :: proc(j: ^DistanceJoint2D) {
	type_cleanup_DistanceJoint2D(j)
	j.auto_distance = true
	j.distance = 1
}

type_cleanup_DistanceJoint2D :: proc(j: ^DistanceJoint2D) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// Holds the two bodies together as one.
@(component={menu="Physics2D/FixedJoint2D", icon="LINK"})
@(typ_guid={guid = "e18a6c40-5f2d-4b97-8c3e-7d4a9b2f6e05"})
FixedJoint2D :: struct {
	using base:       engine.CompData `inspect:"-"`,
	// The other body. Empty: the world.
	connected:        engine.Ref_Local `ref:"Rigidbody2D"`,
	// The two bodies collide with each other.
	enable_collision: bool,
	// Newtons and newton-meters above which the joint breaks. 0 never breaks.
	break_force:      f32 `decor:min(0)`,
	break_torque:     f32 `decor:min(0)`,

	joint:  b2.JointId `json:"-" inspect:"-"`,
	warned: bool `json:"-" inspect:"-"`,
}

type_cleanup_FixedJoint2D :: proc(j: ^FixedJoint2D) {
	_destroy_joint(&j.joint)
	engine.comp_zero(j)
}

// The world point an anchor in `owner`'s own space is at now.
joint_anchor_world :: proc(owner: engine.Transform_Handle, anchor: [2]f32) -> [2]f32 {
	tw := engine.transform_world(owner)
	p := engine.trs_matrix(tw.position, tw.rotation, tw.scale) * [4]f32{anchor.x, anchor.y, 0, 1}
	return p.xy
}

// The connected Rigidbody2D's object, {} for the world (an empty reference)
// or one that is gone.
joint_connected_object :: proc(connected: engine.Ref_Local) -> engine.Transform_Handle {
	if connected.handle == {} do return {}
	rb := cast(^Rigidbody2D)engine.world_pool_get(engine.ctx_world(), connected.handle)
	return rb != nil ? rb.owner : {}
}

// --- Sync ------------------------------------------------------------------------

// The two bodies of a joint on `owner`, ok=false while one does not exist
// yet. `connected` empty is the world: the ground body. A joint on an object
// without a Rigidbody2D says so once.
@(private = "file")
_joint_bodies :: proc(w: ^engine.World, owner: engine.Transform_Handle, connected: engine.Ref_Local, warned: ^bool, kind: string) -> (a, b: b2.BodyId, ok: bool) {
	a, ok = body_of(owner)
	if !ok {
		if _, rb := engine.transform_get_comp(owner, Rigidbody2D); rb == nil && !warned^ {
			warned^ = true
			log.warningf("[Physics2D] the %s on %q does nothing: it needs a Rigidbody2D on its own object", kind, _owner_name(w, owner))
		}
		return {}, {}, false
	}
	if connected.local_id == 0 && connected.handle == {} do return a, _ground(), true
	rb := cast(^Rigidbody2D)engine.world_pool_get(w, connected.handle)
	if rb == nil || !b2.Body_IsValid(rb.body) do return {}, {}, false
	return a, rb.body, true
}

// A static body at the origin, for joints that hold an object to the world.
@(private = "file")
_ground :: proc() -> b2.BodyId {
	if !b2.Body_IsValid(_state.ground) {
		def := b2.DefaultBodyDef()
		def.type = .staticBody
		_state.ground = b2.CreateBody(_state.world, def)
	}
	return _state.ground
}

@(private = "file")
_owner_name :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> string {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	return t != nil ? t.name : fmt.tprintf("%v", tH)
}

// Builds missing joints, removes those of disabled components and pushes the
// live fields. Before the world step.
_sync_joints :: proc(w: ^engine.World) {
	{
		it := engine.pool_iterator(hinge_joint2_ds(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if !b2.Joint_IsValid(j.joint) {
				a, b, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "HingeJoint2D")
				if !ok do continue
				// box2d's angle and motor are body B's turn relative to body
				// A: B is the joint's own object, so a positive speed turns
				// it counterclockwise and the limits are its own turn.
				pivot := joint_anchor_world(j.owner, j.anchor)
				def := b2.DefaultRevoluteJointDef()
				def.bodyIdA = b
				def.bodyIdB = a
				// Both frames point the same way in the world now, so the
				// joint's angle starts at zero.
				def.localFrameA = {p = b2.Body_GetLocalPoint(b, pivot), q = b2.Rot_identity}
				def.localFrameB = {p = b2.Body_GetLocalPoint(a, pivot), q = b2.InvMulRot(b2.Body_GetRotation(a), b2.Body_GetRotation(b))}
				def.collideConnected = j.enable_collision
				j.joint = b2.CreateRevoluteJoint(_state.world, def)
			}
			_push_hinge(j)
		}
	}
	{
		it := engine.pool_iterator(distance_joint2_ds(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if !b2.Joint_IsValid(j.joint) {
				a, b, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "DistanceJoint2D")
				if !ok do continue
				from := joint_anchor_world(j.owner, j.anchor)
				to := j.connected_anchor
				if other := joint_connected_object(j.connected); other != {} do to = joint_anchor_world(other, j.connected_anchor)
				if j.auto_distance do j.distance = linalg.length(to - from)
				def := b2.DefaultDistanceJointDef()
				def.bodyIdA = a
				def.bodyIdB = b
				def.localFrameA.p = b2.Body_GetLocalPoint(a, from)
				def.localFrameB.p = b2.Body_GetLocalPoint(b, to)
				def.length = max(j.distance, 0.005)
				def.collideConnected = j.enable_collision
				j.joint = b2.CreateDistanceJoint(_state.world, def)
			}
			_push_distance(j)
		}
	}
	{
		it := engine.pool_iterator(fixed_joint2_ds(w))
		for j, _ in engine.pool_next(&it) {
			if !j.enabled {
				_destroy_joint(&j.joint)
				continue
			}
			if b2.Joint_IsValid(j.joint) do continue
			a, b, ok := _joint_bodies(w, j.owner, j.connected, &j.warned, "FixedJoint2D")
			if !ok do continue
			// The weld point: this object's origin.
			at := b2.Body_GetPosition(a)
			def := b2.DefaultWeldJointDef()
			def.bodyIdA = a
			def.bodyIdB = b
			// Both frames point the same way in the world now: the weld
			// keeps the bodies' turn relative to each other as it is.
			def.localFrameA = {p = b2.Body_GetLocalPoint(a, at), q = b2.Rot_identity}
			def.localFrameB = {p = b2.Body_GetLocalPoint(b, at), q = b2.InvMulRot(b2.Body_GetRotation(b), b2.Body_GetRotation(a))}
			def.collideConnected = j.enable_collision
			j.joint = b2.CreateWeldJoint(_state.world, def)
		}
	}
}

// The live fields of a hinge, set only when they differ: a change wakes the
// bodies, so a motor started on a sleeping body turns it.
@(private = "file")
_push_hinge :: proc(j: ^HingeJoint2D) {
	id := j.joint
	changed := false
	lo, hi := math.to_radians(min(j.lower_angle, j.upper_angle)), math.to_radians(max(j.lower_angle, j.upper_angle))
	if b2.RevoluteJoint_IsLimitEnabled(id) != j.use_limits {
		b2.RevoluteJoint_EnableLimit(id, j.use_limits)
		changed = true
	}
	if b2.RevoluteJoint_GetLowerLimit(id) != lo || b2.RevoluteJoint_GetUpperLimit(id) != hi {
		b2.RevoluteJoint_SetLimits(id, lo, hi)
		changed = true
	}
	if b2.RevoluteJoint_IsMotorEnabled(id) != j.use_motor {
		b2.RevoluteJoint_EnableMotor(id, j.use_motor)
		changed = true
	}
	speed := math.to_radians(j.motor_speed)
	if b2.RevoluteJoint_GetTargetMotorSpeed(id) != speed {
		b2.RevoluteJoint_SetTargetMotorSpeed(id, speed)
		changed = true
	}
	if b2.RevoluteJoint_GetMaxMotorTorque(id) != j.max_motor_torque {
		b2.RevoluteJoint_SetMaxMotorTorque(id, j.max_motor_torque)
		changed = true
	}
	if changed do b2.Joint_WakeBodies(id)
}

// A rod is the joint's rigid length. A spring springs toward it. A rope has
// no spring force and a limit of the length, so only stretching is stopped.
@(private = "file")
_push_distance :: proc(j: ^DistanceJoint2D) {
	id := j.joint
	changed := false
	spring := j.spring_frequency > 0 || j.max_distance_only
	if b2.DistanceJoint_IsSpringEnabled(id) != spring {
		b2.DistanceJoint_EnableSpring(id, spring)
		changed = true
	}
	if b2.DistanceJoint_GetSpringHertz(id) != j.spring_frequency {
		b2.DistanceJoint_SetSpringHertz(id, j.spring_frequency)
		changed = true
	}
	if b2.DistanceJoint_GetSpringDampingRatio(id) != j.damping_ratio {
		b2.DistanceJoint_SetSpringDampingRatio(id, j.damping_ratio)
		changed = true
	}
	length := max(j.distance, 0.005)
	if b2.DistanceJoint_GetRestLength(id) != length {
		b2.DistanceJoint_SetRestLength(id, length)
		changed = true
	}
	if b2.DistanceJoint_IsLimitEnabled(id) != j.max_distance_only {
		b2.DistanceJoint_EnableLimit(id, j.max_distance_only)
		changed = true
	}
	if j.max_distance_only && b2.DistanceJoint_GetUpperLimit(id) != length {
		b2.DistanceJoint_SetLimits(id, 0, length)
		changed = true
	}
	if changed do b2.Joint_WakeBodies(id)
}

// Breaks the joints whose force or torque in the step went over their
// limits. After the world step.
_break_joints :: proc(w: ^engine.World) {
	check :: proc(id: ^b2.JointId, enabled: ^bool, force, torque: f32) {
		if !b2.Joint_IsValid(id^) || force <= 0 && torque <= 0 do return
		over := force > 0 && linalg.length(b2.Joint_GetConstraintForce(id^)) > force
		over ||= torque > 0 && abs(b2.Joint_GetConstraintTorque(id^)) > torque
		if !over do return
		_destroy_joint(id)
		enabled^ = false
	}
	{
		it := engine.pool_iterator(hinge_joint2_ds(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, j.break_torque)
	}
	{
		it := engine.pool_iterator(distance_joint2_ds(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, 0)
	}
	{
		it := engine.pool_iterator(fixed_joint2_ds(w))
		for j, _ in engine.pool_next(&it) do check(&j.joint, &j.enabled, j.break_force, j.break_torque)
	}
}

_destroy_joint :: proc(joint: ^b2.JointId) {
	if _state.world_ready && b2.Joint_IsValid(joint^) do b2.DestroyJoint(joint^)
	joint^ = {}
}
