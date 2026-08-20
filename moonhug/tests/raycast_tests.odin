package tests

import "core:testing"
import "../engine"

@(test)
test_ray_hit_aabb :: proc(t: ^testing.T) {
	unit := struct{ lo, hi: [3]f32 }{{-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}}

	// Straight-on hit from +Z.
	hit_t, hit := engine.ray_hit_aabb(engine.Ray{{0, 0, 5}, {0, 0, -1}}, unit.lo, unit.hi)
	testing.expect(t, hit, "head-on ray should hit")
	testing.expect(t, abs(hit_t - 4.5) < 1e-5, "hit distance should be 4.5")

	// Miss to the side.
	_, hit = engine.ray_hit_aabb(engine.Ray{{2, 0, 5}, {0, 0, -1}}, unit.lo, unit.hi)
	testing.expect(t, !hit, "offset ray should miss")

	// Behind the origin: box is in -direction.
	_, hit = engine.ray_hit_aabb(engine.Ray{{0, 0, 5}, {0, 0, 1}}, unit.lo, unit.hi)
	testing.expect(t, !hit, "box behind ray should miss")

	// Origin inside the box → t = 0.
	hit_t, hit = engine.ray_hit_aabb(engine.Ray{{0, 0, 0}, {0, 0, -1}}, unit.lo, unit.hi)
	testing.expect(t, hit && hit_t == 0, "origin inside should hit at t=0")

	// Axis-parallel ray sliding along a face plane, outside the slab.
	_, hit = engine.ray_hit_aabb(engine.Ray{{0, 2, 5}, {0, 0, -1}}, unit.lo, unit.hi)
	testing.expect(t, !hit, "parallel ray outside slab should miss")
}

@(test)
test_ray_hit_triangle :: proc(t: ^testing.T) {
	a := [3]f32{-1, -1, 0}
	b := [3]f32{1, -1, 0}
	c := [3]f32{0, 1, 0}

	// Center hit from the front.
	hit_t, hit := engine.ray_hit_triangle(engine.Ray{{0, 0, 3}, {0, 0, -1}}, a, b, c)
	testing.expect(t, hit, "center ray should hit")
	testing.expect(t, abs(hit_t - 3) < 1e-5, "hit distance should be 3")

	// Double-sided: same triangle from behind.
	_, hit = engine.ray_hit_triangle(engine.Ray{{0, 0, -3}, {0, 0, 1}}, a, b, c)
	testing.expect(t, hit, "backface ray should hit (double-sided)")

	// Outside the triangle but inside its bounding square.
	_, hit = engine.ray_hit_triangle(engine.Ray{{-0.9, 0.9, 3}, {0, 0, -1}}, a, b, c)
	testing.expect(t, !hit, "corner-adjacent miss")

	// Triangle behind the ray.
	_, hit = engine.ray_hit_triangle(engine.Ray{{0, 0, 3}, {0, 0, 1}}, a, b, c)
	testing.expect(t, !hit, "triangle behind ray should miss")
}
