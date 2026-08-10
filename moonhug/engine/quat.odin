package engine

import "core:math"
import "core:math/linalg"

QUAT_IDENTITY :: [4]f32{0, 0, 0, 1}

quat_to_native :: proc(q: [4]f32) -> quaternion128 {
	return quaternion(x = q.x, y = q.y, z = q.z, w = q.w)
}

quat_from_native :: proc(q: quaternion128) -> [4]f32 {
	return {quaternion128_x(q), quaternion128_y(q), quaternion128_z(q), quaternion128_w(q)}
}

quaternion128_x :: proc(q: quaternion128) -> f32 { return imag(q) }
quaternion128_y :: proc(q: quaternion128) -> f32 { return jmag(q) }
quaternion128_z :: proc(q: quaternion128) -> f32 { return kmag(q) }
quaternion128_w :: proc(q: quaternion128) -> f32 { return real(q) }

quat_to_matrix3 :: proc(q: [4]f32) -> linalg.Matrix3f32 {
	return linalg.matrix3_from_quaternion(quat_to_native(q))
}

quat_from_euler_xyz :: proc(x_deg, y_deg, z_deg: f32) -> [4]f32 {
	q := linalg.quaternion_from_euler_angles(
		math.to_radians(x_deg),
		math.to_radians(y_deg),
		math.to_radians(z_deg),
		.XYZ,
	)
	return quat_from_native(q)
}

// Euler angles (degrees, XYZ) for display and authoring.
//
// A rotation has TWO XYZ spellings — (x, y, z) and (x±180, 180−y, z±180) name
// the same orientation — and the closed-form solution returns whichever its
// formula lands on. That is canonical but often not the one a person typed:
// asking for (0, -150, 0) reads back as (180, -30, -180), which is correct and
// unrecognisable.
//
// The spelling with the smallest secondary angles is preferred, because it is
// the one a human would write. Turning an object about a single axis then shows
// that axis moving and the other two at rest, however far it turns.
quat_to_euler_xyz :: proc(q: [4]f32) -> [3]f32 {
	nq := quat_to_native(q)
	rx, ry, rz := linalg.euler_angles_from_quaternion(nq, .XYZ)
	a := [3]f32{math.to_degrees(rx), math.to_degrees(ry), math.to_degrees(rz)}
	b := _euler_xyz_alternate(a)

	// "Simplest" = smallest X and Z, the axes a single-axis turn leaves alone.
	if abs(b.x) + abs(b.z) < abs(a.x) + abs(a.z) - 0.001 {
		return b
	}
	return a
}

// The other XYZ solution for the same orientation.
@(private = "file")
_euler_xyz_alternate :: proc(e: [3]f32) -> [3]f32 {
	return {_wrap_deg(e.x + 180), _wrap_deg(180 - e.y), _wrap_deg(e.z + 180)}
}

@(private = "file")
_wrap_deg :: proc(a: f32) -> f32 {
	r := a
	for r > 180 do r -= 360
	for r < -180 do r += 360
	return r
}
