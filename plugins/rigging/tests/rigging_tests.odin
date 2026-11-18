package rigging_tests

// TwoBoneIK and SpringBones (plugins/rigging): the solve on bare points,
// then both components on small chains of objects built in code.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import rigging ".."

@(private = "file")
_near :: proc(a, b: [3]f32, eps: f32 = 0.002) -> bool {
	return linalg.length(a - b) < eps
}

// Where the joints land when the solve's turns are applied.
@(private = "file")
_posed :: proc(a, b, c: [3]f32, root_turn, mid_turn: rigging.Quat) -> (b1, c1: [3]f32) {
	b1 = a + linalg.quaternion128_mul_vector3(root_turn, b - a)
	c1 = b1 + linalg.quaternion128_mul_vector3(root_turn * mid_turn, c - b)
	return
}

@(test)
test_two_bone_solve_reaches_and_keeps_lengths :: proc(t: ^testing.T) {
	a, b, c := [3]f32{0, 0, 0}, [3]f32{0, -1, 0}, [3]f32{1, -1, 0}

	// Inside reach, off the limb's own plane too.
	for goal in ([][3]f32{{1.2, 0.3, 0}, {0.4, -0.5, 0.8}, {-1, 0.2, -0.6}, {0.1, 0, 0}}) {
		rt, mt := rigging.two_bone_solve(a, b, c, goal)
		b1, c1 := _posed(a, b, c, rt, mt)
		testing.expectf(t, _near(c1, goal), "the tip reaches %v: %v", goal, c1)
		testing.expectf(t, abs(linalg.length(b1 - a) - 1) < 0.001 && abs(linalg.length(c1 - b1) - 1) < 0.001, "the bones keep their lengths for %v", goal)
	}

	// Out of reach: the limb is straight toward the target.
	rt, mt := rigging.two_bone_solve(a, b, c, {5, 0, 0})
	b1, c1 := _posed(a, b, c, rt, mt)
	testing.expectf(t, _near(c1, {2, 0, 0}, 0.03) && _near(b1, {1, 0, 0}, 0.03), "straight toward a far target: %v %v", b1, c1)

	// The hint picks the side the middle joint bends to.
	goal := [3]f32{1.2, 0, 0}
	for side in ([]f32{1, -1}) {
		hint := [3]f32{0.6, 0, side * 3}
		rt, mt = rigging.two_bone_solve(a, b, c, goal, hint, true)
		b1, c1 = _posed(a, b, c, rt, mt)
		testing.expectf(t, _near(c1, goal), "the tip still reaches with a hint: %v", c1)
		testing.expectf(t, b1.z * side > 0.3 && abs(b1.y) < 0.01, "the middle joint is on the hint's side (%v): %v", side, b1)
	}

	// A straight limb has no bend plane of its own: it still solves.
	rt, mt = rigging.two_bone_solve({0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {1, 1, 0})
	_, c1 = _posed({0, 0, 0}, {1, 0, 0}, {2, 0, 0}, rt, mt)
	testing.expectf(t, _near(c1, {1, 1, 0}), "a straight limb bends to reach: %v", c1)
}

@(private = "file")
_object :: proc(name: string, parent: engine.Transform_Handle, pos: [3]f32) -> engine.Transform_Handle {
	h := engine.transform_new(name, parent)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h)).position = pos
	return h
}

@(private = "file")
_pos :: proc(h: engine.Transform_Handle) -> [3]f32 {
	return engine.transform_world(h).position
}

@(test)
test_two_bone_ik_component_moves_the_tip_to_the_target :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// An arm under a turned and moved body, so parents' rotations count.
	body := _object("Body", {}, {3, 1, -2})
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(body)).rotation = engine.quat_from_euler_xyz(10, 50, -20)
	upper := _object("Upper", body, {0.2, 1.4, 0})
	fore := _object("Fore", upper, {0, -0.3, 0.05})
	hand := _object("Hand", fore, {0, -0.28, -0.05})
	target := _object("Target", {}, {3.3, 2.2, -1.8})

	_, raw := engine.transform_add_comp(body, .TwoBoneIK)
	ik := cast(^rigging.TwoBoneIK)raw
	rigging.type_reset_TwoBoneIK(ik)
	ik.enabled = true
	ik.tip = engine.Ref_Local{handle = engine.Handle(hand)}
	ik.target = engine.Ref_Local{handle = engine.Handle(target)}

	root, mid, tip, ok := rigging.two_bone_joints(ik)
	testing.expect(t, ok && root == upper && mid == fore && tip == hand, "the tip's parent and grandparent are the limb")

	start := _pos(hand)
	shoulder := _pos(upper)
	upper_len := linalg.length(_pos(fore) - shoulder)

	ik.weight = 0
	rigging.two_bone_apply(ik)
	testing.expect(t, _near(_pos(hand), start), "weight 0 leaves the pose")

	ik.weight = 0.5
	rigging.two_bone_apply(ik)
	half := _pos(hand)
	testing.expectf(t, !_near(half, start, 0.05) && !_near(half, _pos(target), 0.05), "weight 0.5 is part of the way: %v", half)

	ik.weight = 1
	rigging.two_bone_apply(ik)
	testing.expectf(t, _near(_pos(hand), _pos(target)), "the hand is on the target: %v", _pos(hand))
	testing.expect(t, _near(_pos(upper), shoulder) && abs(linalg.length(_pos(fore) - shoulder) - upper_len) < 0.001, "the shoulder stays, the upper arm keeps its length")

	// The update solves again as the target moves.
	engine.transform_set_world_position(target, shoulder + (_pos(target) - shoulder) * 0.8) // nearer, so within reach
	rigging.two_bone_ik_update(1.0 / 60)
	testing.expectf(t, _near(_pos(hand), _pos(target)), "the hand follows the target: %v", _pos(hand))

	// match_rotation turns the hand like the target.
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(target)).rotation = engine.quat_from_euler_xyz(0, 90, 0)
	ik.match_rotation = true
	rigging.two_bone_apply(ik)
	got := engine.quat_to_native(engine.transform_world(hand).rotation)
	want := engine.quat_to_native(engine.transform_world(target).rotation)
	testing.expectf(t, abs(linalg.dot(got, want)) > 0.9999, "the hand takes the target's rotation: %v", got)

	// No target: nothing moves.
	before := _pos(hand)
	ik.target = {}
	rigging.two_bone_apply(ik)
	testing.expect(t, _near(_pos(hand), before), "no target, no change")
}

// A chain of three bones along +x from `at`, each `step` long, and its
// SpringBones on the first.
@(private = "file")
_chain :: proc(at: [3]f32) -> (bones: [4]engine.Transform_Handle, s: ^rigging.SpringBones) {
	bones[0] = _object("Bone0", {}, at)
	for i in 1 ..< 4 do bones[i] = _object("Bone", bones[i - 1], {0.5, 0, 0})
	_, raw := engine.transform_add_comp(bones[0], .SpringBones)
	s = cast(^rigging.SpringBones)raw
	rigging.type_reset_SpringBones(s)
	s.enabled = true
	return
}

@(private = "file")
_DT :: f32(1.0 / 60)

@(test)
test_spring_bones_lag_and_return :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bones, s := _chain({0, 0, 0})
	s.stiffness = 4

	// At rest nothing moves.
	for _ in 0 ..< 30 do rigging.spring_bones_step(s, _DT)
	testing.expectf(t, _near(_pos(bones[3]), {1.5, 0, 0}), "a still chain keeps its pose: %v", _pos(bones[3]))
	testing.expect_value(t, len(s.joints), 3)

	// The root jumps up: the end lags behind, the bones keep their lengths.
	engine.transform_set_world_position(bones[0], {0, 1, 0})
	rigging.spring_bones_step(s, _DT)
	end := _pos(bones[3])
	testing.expectf(t, end.y < 0.9, "the end lags behind the root: %v", end)
	for i in 0 ..< 3 {
		d := linalg.length(_pos(bones[i + 1]) - _pos(bones[i]))
		testing.expectf(t, abs(d - 0.5) < 0.001, "bone %v keeps its length: %v", i, d)
	}

	// Then it swings back to the pose.
	for _ in 0 ..< 600 do rigging.spring_bones_step(s, _DT)
	testing.expectf(t, _near(_pos(bones[3]), {1.5, 1, 0}, 0.02), "the chain returns to its pose: %v", _pos(bones[3]))

	// A rotation written from outside is the new pose to return to.
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(bones[0])).rotation = engine.quat_from_native(linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1}))
	for _ in 0 ..< 600 do rigging.spring_bones_step(s, _DT)
	testing.expectf(t, _near(_pos(bones[3]), {0, 2.5, 0}, 0.02), "the chain settles on the pose written from outside: %v", _pos(bones[3]))
}

@(test)
test_spring_bones_gravity_and_colliders :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bones, s := _chain({0, 0, 0})
	s.stiffness = 0.5
	s.gravity = {0, -3, 0}
	for _ in 0 ..< 600 do rigging.spring_bones_step(s, _DT)
	hang := _pos(bones[3])
	testing.expectf(t, hang.y < -1.0, "gravity pulls the chain down: %v", hang)

	// A sphere under the chain: no bone end goes inside it.
	body := _object("Body", {}, {0, 0, 0})
	ball := _object("Ball", body, {0.4, -0.9, 0})
	_, raw := engine.transform_add_comp(ball, .SpringBoneCollider)
	col := cast(^rigging.SpringBoneCollider)raw
	rigging.type_reset_SpringBoneCollider(col)
	col.enabled = true
	col.radius = 0.6
	s.colliders = engine.Ref_Local{handle = engine.Handle(body)}
	s.radius = 0.05
	for _ in 0 ..< 600 do rigging.spring_bones_step(s, _DT)
	center, radius := rigging.spring_collider_sphere(col)
	for i in 1 ..< 4 {
		d := linalg.length(_pos(bones[i]) - center)
		testing.expectf(t, d > radius + s.radius - 0.02, "bone end %v stays out of the sphere: %v from its center", i, d)
	}
	testing.expectf(t, !_near(_pos(bones[3]), hang, 0.05), "the sphere changed where the chain hangs: %v", _pos(bones[3]))

	// Another object's colliders take no part.
	s.colliders = {}
	for _ in 0 ..< 600 do rigging.spring_bones_step(s, _DT)
	testing.expectf(t, _near(_pos(bones[3]), hang, 0.02), "with no colliders the chain hangs as before: %v", _pos(bones[3]))
}
