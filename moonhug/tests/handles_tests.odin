package tests

// The geometry the scene-view handles rest on (editor/handles).

import "core:testing"
import "../engine"
import "../editor/handles"

@(test)
test_handles_ray_plane_hits_and_misses :: proc(t: ^testing.T) {
	// Straight down onto the XZ plane from y = 10.
	ray := engine.Ray{origin = {3, 10, -2}, direction = {0, -1, 0}}
	p, ok := handles.ray_plane(ray, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, ok, "ray facing the plane hits it")
	testing.expect_value(t, p, [3]f32{3, 0, -2})

	// Parallel to the plane: no hit.
	flat := engine.Ray{origin = {0, 1, 0}, direction = {1, 0, 0}}
	_, ok2 := handles.ray_plane(flat, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, !ok2, "ray parallel to the plane misses")

	// Oblique onto the canvas plane z = 0.
	slant := engine.Ray{origin = {0, 0, 5}, direction = {1, 1, -1}}
	q, ok3 := handles.ray_plane(slant, {0, 0, 0}, {0, 0, 1})
	testing.expect(t, ok3, "oblique ray hits")
	testing.expect_value(t, q, [3]f32{5, 5, 0})
}
