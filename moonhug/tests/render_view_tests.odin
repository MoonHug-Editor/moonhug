package tests

// Render_View math that runs headless (no gfx init needed).

import "core:math/linalg"
import "core:testing"
import "../engine"

// cam_pos must round-trip through render_view_make: build a look_at view from
// a known eye and expect it back (specular shaders depend on it being the
// true camera world position, not an NDC-space artifact).
@(test)
test_render_view_cam_pos_derivation :: proc(t: ^testing.T) {
	eye := [3]f32{3, 4, -5}
	view := linalg.matrix4_look_at_f32(eye, {0, 0, 0}, {0, 1, 0})
	proj := linalg.matrix4_perspective_f32(1.0, 16.0 / 9.0, 0.1, 100)

	rv := engine.render_view_make(view, proj, 1920, 1080, ~u32(0))
	testing.expect(t, linalg.length(rv.cam_pos - eye) < 1e-4, "cam_pos should equal the look_at eye")
}
