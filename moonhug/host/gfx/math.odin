// Projection helpers for SDL_GPU's clip space: z ∈ [0,1] (Vulkan/Metal/D3D
// style). core:math/linalg's perspective is GL-style z ∈ [-1,1] — don't mix.
package gfx

import "core:math"

// fovy in radians. Right-handed, looking down -Z, depth 0 at near.
matrix4_perspective_z01 :: proc(fovy, aspect, near, far: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(fovy * 0.5)
	return matrix[4, 4]f32{
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, far / (near - far), (near * far) / (near - far),
		0, 0, -1, 0,
	}
}

matrix4_ortho_z01 :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{
		2 / (right - left), 0, 0, (left + right) / (left - right),
		0, 2 / (top - bottom), 0, (bottom + top) / (bottom - top),
		0, 0, 1 / (near - far), near / (near - far),
		0, 0, 0, 1,
	}
}

// Screen-space pixels: origin top-left, y down — for debug text / overlays.
matrix4_ortho_pixels :: proc(width, height: f32) -> matrix[4, 4]f32 {
	return matrix4_ortho_z01(0, width, height, 0, -1, 1)
}
