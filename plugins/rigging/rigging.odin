package rigging

// Rigging (plugins/rigging/docs/_index.md): components that change a pose
// after animation wrote it, so they work on any hierarchy of objects, with
// or without the animation plugin.
//
// - TwoBoneIK bends a limb of two bones so its end reaches a target.
// - SpringBones lets a chain of bones lag and swing as its root moves.
//
// Both run in @(late_update), TwoBoneIK first: a spring chain hanging off a
// limb follows where the limb ends up. They run while the game runs.

import "core:math"
import "core:math/linalg"

Quat :: quaternion128

// The shortest rotation that turns direction `from` onto `to`. Both are
// normalized here. Opposite directions turn half a turn around any axis
// across `from`.
quat_from_to :: proc(from, to: [3]f32) -> Quat {
	a := linalg.normalize0(from)
	b := linalg.normalize0(to)
	if a == {} || b == {} do return linalg.QUATERNIONF32_IDENTITY
	d := clamp(linalg.dot(a, b), -1, 1)
	if d > 0.999999 do return linalg.QUATERNIONF32_IDENTITY
	if d < -0.999999 {
		axis := linalg.cross(a, [3]f32{1, 0, 0})
		if linalg.length(axis) < 1e-4 do axis = linalg.cross(a, [3]f32{0, 1, 0})
		return linalg.quaternion_angle_axis_f32(math.PI, linalg.normalize(axis))
	}
	return linalg.quaternion_angle_axis_f32(math.acos(d), linalg.normalize(linalg.cross(a, b)))
}
