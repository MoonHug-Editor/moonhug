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

quat_to_euler_xyz :: proc(q: [4]f32) -> [3]f32 {
	nq := quat_to_native(q)
	rx, ry, rz := linalg.euler_angles_from_quaternion(nq, .XYZ)
	return {math.to_degrees(rx), math.to_degrees(ry), math.to_degrees(rz)}
}
