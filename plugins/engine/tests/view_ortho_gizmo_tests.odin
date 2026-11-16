package engine_tests

// The direction to the viewer and the world size of a pixel, in a
// perspective and in an orthographic view (libs/core/view_math.odin,
// libs/gizmos). In an orthographic view every ray is parallel: a point at the
// view's edge sees the viewer the same way as one at its centre, and a pixel
// covers the same world length at any depth.

import "core:math"
import "core:math/linalg"
import "core:testing"
import core "moonhug:libs/core"
import "moonhug:libs/gfx"
import "moonhug:libs/gizmos"
import "moonhug:packages/engine/editor/scene_tools"

@(private = "file")
_near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 0.001
}

@(test)
test_view_direction_to_viewer_and_pixel_size :: proc(t: ^testing.T) {
	eye := [3]f32{0, 0, 10}
	view := linalg.matrix4_look_at_f32(eye, {0, 0, 0}, {0, 1, 0})
	to_eye := [3]f32{0, 0, 1} // the viewer looks down -Z

	ortho := core.render_view_make(view, gfx.matrix4_ortho_z01(-8, 8, -4, 4, -100, 100), 1600, 800, ~u32(0), .SceneView)
	centre, edge, deep := [3]f32{0, 0, 0}, [3]f32{7, 3, 0}, [3]f32{7, 3, -40}
	testing.expect(t, _near(core.render_view_dir_to_viewer(ortho, centre), to_eye), "ortho, centre")
	testing.expect(t, _near(core.render_view_dir_to_viewer(ortho, edge), to_eye), "ortho, a point at the edge sees the viewer the same way")
	// 800 pixels span 8 world units: a pixel is 0.01 everywhere.
	for p in ([?][3]f32{centre, edge, deep}) {
		got := gizmos.helper_pixel_in(ortho, p, 100)
		testing.expectf(t, abs(got - 1) < 0.01, "ortho: 100 px at %v is %v world units, want 1", p, got)
	}

	persp := core.render_view_make(view, gfx.matrix4_perspective_z01(math.to_radians(f32(45)), 2, 0.1, 1000), 1600, 800, ~u32(0), .SceneView)
	testing.expect(t, _near(core.render_view_dir_to_viewer(persp, edge), linalg.normalize(eye - edge)), "perspective: toward the eye")
	// Twice as far, twice the world length for the same pixels.
	one := gizmos.helper_pixel_in(persp, {0, 0, 0}, 100)
	two := gizmos.helper_pixel_in(persp, {0, 0, -10}, 100)
	testing.expectf(t, abs(two / one - 2) < 0.02, "perspective: %v at 10, %v at 20", one, two)
}

// The transform gizmo keeps its size on screen: a part of the view's height
// in an orthographic view, wherever the object is.
@(test)
test_gizmo_size_in_an_orthographic_view :: proc(t: ^testing.T) {
	view := linalg.matrix4_look_at_f32({0, 0, 10}, {0, 0, 0}, {0, 1, 0})
	ortho := core.render_view_make(view, gfx.matrix4_ortho_z01(-8, 8, -4, 4, -100, 100), 1600, 800, ~u32(0), .SceneView)
	at_centre := scene_tools.gizmo_size(ortho, {0, 0, 0})
	testing.expectf(t, abs(at_centre - 8 * 0.181) < 0.001, "a part of the 8 unit view height, got %v", at_centre)
	testing.expect_value(t, scene_tools.gizmo_size(ortho, {7, 3, -40}), at_centre)
}
