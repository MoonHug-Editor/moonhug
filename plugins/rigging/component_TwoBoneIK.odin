package rigging

// TwoBoneIK (plugins/rigging/docs/components/TwoBoneIK.md): turns the two
// bones of a limb so the limb's end reaches a target. The three joints are
// `root` (shoulder, hip), `mid` (elbow, knee) and `tip` (hand, foot).
//
// - Only `tip` has to be set: `mid` and `root` default to its parent and
//   grandparent.
// - The bones keep their lengths. A target further than the limb is long
//   leaves the limb straight toward it.
// - The limb bends the way it is already bent. `hint` chooses the side
//   instead: the middle joint points toward it.
// - `weight` blends from the pose as it was (0) to the solved one (1).
// - `match_rotation` also turns the tip to the target's rotation.

import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"

@(component={menu="Rigging/TwoBoneIK"})
@(typ_guid={guid="8b89d019-7d2f-46ac-b2d3-a3ac5b8ddd63"})
TwoBoneIK :: struct {
	using base:     engine.CompData `inspect:"-"`,
	tip:            engine.Ref_Local `ref:"Transform"`, // the limb's end: a hand, a foot
	mid:            engine.Ref_Local `ref:"Transform"`, // the middle joint, empty = the tip's parent
	root:           engine.Ref_Local `ref:"Transform"`, // the first joint, empty = the middle joint's parent
	target:         engine.Ref_Local `ref:"Transform"`, // where the tip goes
	hint:           engine.Ref_Local `ref:"Transform"`, // the middle joint bends toward it, empty = as posed
	weight:         f32 `decor:range(0, 1)`,
	match_rotation: bool, // the tip takes the target's rotation too
}

type_reset_TwoBoneIK :: proc(ik: ^TwoBoneIK) {
	engine.comp_zero(ik)
	ik.weight = 1
}

// The limb's three joints, the defaults filled in. ok false when one is
// missing.
two_bone_joints :: proc(ik: ^TwoBoneIK) -> (root, mid, tip: engine.Transform_Handle, ok: bool) {
	w := engine.ctx_world()
	parent_of :: proc(w: ^engine.World, h: engine.Transform_Handle) -> engine.Transform_Handle {
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do return {}
		return engine.Transform_Handle(t.parent.handle)
	}
	tip = engine.Transform_Handle(ik.tip.handle)
	mid = engine.Transform_Handle(ik.mid.handle)
	root = engine.Transform_Handle(ik.root.handle)
	if mid == {} do mid = parent_of(w, tip)
	if root == {} do root = parent_of(w, mid)
	for h in ([3]engine.Transform_Handle{root, mid, tip}) {
		if h == {} || !engine.pool_valid(&w.transforms, engine.Handle(h)) do return {}, {}, {}, false
	}
	return root, mid, tip, true
}

// The solve, on world positions: joints `a`, `b`, `c` and target `t`.
// The solved world rotations are
//   root: root_turn * root's own
//   mid:  root_turn * mid_turn * mid's own
// The bone lengths |ab| and |bc| stay. `hint` is used when `has_hint`.
two_bone_solve :: proc(a, b, c, t: [3]f32, hint: [3]f32 = {}, has_hint := false) -> (root_turn, mid_turn: Quat) {
	root_turn = linalg.QUATERNIONF32_IDENTITY
	mid_turn = linalg.QUATERNIONF32_IDENTITY
	EPS :: f32(1e-4)
	lab := linalg.length(b - a)
	lcb := linalg.length(c - b)
	if lab < EPS || lcb < EPS do return
	lat := clamp(linalg.length(t - a), EPS, lab + lcb - EPS)

	angle :: proc(u, v: [3]f32) -> f32 {
		return math.acos(clamp(linalg.dot(linalg.normalize0(u), linalg.normalize0(v)), -1, 1))
	}
	// The angles now, and the ones a triangle with these three sides has.
	ac_ab_0 := angle(c - a, b - a)
	ba_bc_0 := angle(a - b, c - b)
	ac_ab_1 := math.acos(clamp((lcb * lcb - lab * lab - lat * lat) / (-2 * lab * lat), -1, 1))
	ba_bc_1 := math.acos(clamp((lat * lat - lab * lab - lcb * lcb) / (-2 * lab * lcb), -1, 1))

	// The axis the limb bends around: across its plane as posed. A straight
	// limb has no plane, so the hint gives one, else any axis across the limb.
	axis := linalg.cross(c - a, b - a)
	if linalg.length(axis) < EPS * lab * lcb {
		if has_hint do axis = linalg.cross(c - a, hint - a)
		if linalg.length(axis) < EPS do axis = linalg.cross(c - a, [3]f32{0, 0, 1})
		if linalg.length(axis) < EPS do axis = linalg.cross(c - a, [3]f32{0, 1, 0})
	}
	axis = linalg.normalize0(axis)
	open_root := linalg.quaternion_angle_axis_f32(ac_ab_1 - ac_ab_0, axis)
	mid_turn = linalg.quaternion_angle_axis_f32(ba_bc_1 - ba_bc_0, axis)

	// Where the tip is after the bend, then the swing that carries it onto
	// the line to the target.
	b1 := a + linalg.quaternion128_mul_vector3(open_root, b - a)
	c1 := b1 + linalg.quaternion128_mul_vector3(open_root * mid_turn, c - b)
	swing := quat_from_to(c1 - a, t - a)
	root_turn = swing * open_root

	// The hint: roll the limb around the root-to-target line until the middle
	// joint is on the hint's side.
	if has_hint {
		n := linalg.normalize0(t - a)
		b2 := a + linalg.quaternion128_mul_vector3(root_turn, b - a)
		flat :: proc(v, n: [3]f32) -> [3]f32 { return v - n * linalg.dot(v, n) }
		from := flat(b2 - a, n)
		to := flat(hint - a, n)
		if linalg.length(from) > EPS && linalg.length(to) > EPS {
			root_turn = quat_from_to(from, to) * root_turn
		}
	}
	return
}

// Solves one limb now. The update below calls it for every enabled TwoBoneIK.
// Code that moves a target after the late update calls it itself.
two_bone_apply :: proc(ik: ^TwoBoneIK) {
	if ik.weight <= 0 do return
	w := engine.ctx_world()
	target := engine.Transform_Handle(ik.target.handle)
	if target == {} || !engine.pool_valid(&w.transforms, engine.Handle(target)) do return
	root, mid, tip, ok := two_bone_joints(ik)
	if !ok do return

	rw := engine.transform_world(root)
	mw := engine.transform_world(mid)
	tw := engine.transform_world(tip)
	goal := engine.transform_world(target)
	hint := engine.Transform_Handle(ik.hint.handle)
	has_hint := hint != {} && engine.pool_valid(&w.transforms, engine.Handle(hint))
	hint_pos: [3]f32
	if has_hint do hint_pos = engine.transform_world(hint).position

	root_turn, mid_turn := two_bone_solve(rw.position, mw.position, tw.position, goal.position, hint_pos, has_hint)
	weight := min(ik.weight, 1)
	if weight < 1 {
		id := linalg.QUATERNIONF32_IDENTITY
		// The middle joint's turn is blended in the root's frame, so both
		// blends meet the solved pose at 1.
		full_mid := root_turn * mid_turn
		root_turn = linalg.quaternion_slerp(id, root_turn, weight)
		mid_turn = linalg.quaternion_inverse(root_turn) * linalg.quaternion_slerp(id, full_mid, weight)
	}
	root_rot := root_turn * engine.quat_to_native(rw.rotation)
	mid_rot := root_turn * mid_turn * engine.quat_to_native(mw.rotation)
	// Root first: a world rotation is stored relative to the parent's.
	engine.transform_set_world_rotation(root, engine.quat_from_native(linalg.quaternion_normalize(root_rot)))
	engine.transform_set_world_rotation(mid, engine.quat_from_native(linalg.quaternion_normalize(mid_rot)))
	if ik.match_rotation {
		now := engine.quat_to_native(engine.transform_world(tip).rotation)
		want := engine.quat_to_native(goal.rotation)
		engine.transform_set_world_rotation(tip, engine.quat_from_native(linalg.quaternion_slerp(now, want, weight)))
	}
}

@(late_update={order=0})
two_bone_ik_update :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	pool := two_bone_i_ks(w)
	if pool == nil do return
	it := engine.pool_iterator(pool)
	for ik, _ in engine.pool_next(&it) {
		if !ik.enabled || !engine.transform_active_in_hierarchy(ik.owner) do continue
		two_bone_apply(ik)
	}
}
