package engine

// Ray intersection helpers for scene picking (editor) and game queries.
// `Ray` lives in render.odin (camera_screen_ray / render_view_screen_ray).

// Slab test. Returns the nearest non-negative hit parameter. Works with an
// UNNORMALIZED direction — t stays comparable across objects as long as all
// rays derive from the same world ray (local-space picking relies on this).
ray_hit_aabb :: proc(ray: Ray, aabb_min, aabb_max: [3]f32) -> (t: f32, hit: bool) {
	t_enter := f32(-1e30)
	t_exit := f32(1e30)
	for axis in 0 ..< 3 {
		d := ray.direction[axis]
		o := ray.origin[axis]
		if abs(d) < 1e-12 {
			// Parallel to the slab: must already be inside it.
			if o < aabb_min[axis] || o > aabb_max[axis] do return 0, false
			continue
		}
		inv := 1 / d
		t0 := (aabb_min[axis] - o) * inv
		t1 := (aabb_max[axis] - o) * inv
		if t0 > t1 do t0, t1 = t1, t0
		if t0 > t_enter do t_enter = t0
		if t1 < t_exit do t_exit = t1
	}
	if t_enter > t_exit || t_exit < 0 do return 0, false
	return max(t_enter, 0), true
}

// Möller–Trumbore, double-sided (sprites are viewed from both sides).
ray_hit_triangle :: proc(ray: Ray, a, b, c: [3]f32) -> (t: f32, hit: bool) {
	EPS :: f32(1e-9)
	edge1 := b - a
	edge2 := c - a
	h := _cross(ray.direction, edge2)
	det := _dot(edge1, h)
	if abs(det) < EPS do return 0, false // parallel

	inv_det := 1 / det
	s := ray.origin - a
	u := _dot(s, h) * inv_det
	if u < 0 || u > 1 do return 0, false

	q := _cross(s, edge1)
	v := _dot(ray.direction, q) * inv_det
	if v < 0 || u + v > 1 do return 0, false

	t = _dot(edge2, q) * inv_det
	if t < 0 do return 0, false
	return t, true
}

@(private = "file")
_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private = "file")
_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}
