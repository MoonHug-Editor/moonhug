package engine_tests

// The Camera's projection (plugins/engine/component_Camera.odin,
// camera_render_view): a perspective camera draws a thing smaller the farther
// it is, an orthographic one draws it the same size at every distance, with
// orthographic_size as half the view's height.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"

// A camera at (0, 0, 10) looking down -Z.
@(private = "file")
_camera :: proc() -> ^engine.Camera {
	camH := engine.transform_new("Camera")
	w := engine.ctx_world()
	ct := engine.pool_get(&w.transforms, engine.Handle(camH))
	ct.position = {0, 0, 10}
	_, ptr := engine.transform_add_comp(camH, .Camera)
	cam := cast(^engine.Camera)ptr
	engine.type_reset_Camera(cam)
	return cam
}

// The viewport pixel (origin top-left) a world point lands on.
@(private = "file")
_pixel :: proc(v: engine.Render_View, p: [3]f32) -> [2]f32 {
	c := v.view_proj * [4]f32{p.x, p.y, p.z, 1}
	ndc := c.xy / c.w
	return {(ndc.x + 1) * 0.5 * v.width, (1 - ndc.y) * 0.5 * v.height}
}

@(private = "file")
_near :: proc(a, b: [$N]f32) -> bool {
	return linalg.length(a - b) < 0.001
}

@(test)
test_orthographic_camera_keeps_sizes_at_every_distance :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	cam := _camera()
	cam.projection = .Orthographic
	cam.orthographic_size = 2
	v := engine.camera_render_view(cam, 200, 100)

	// 2 half high, so 4 half wide at aspect 2: (4, 2) is the top-right corner
	// near the camera and far from it alike.
	testing.expect(t, _near(_pixel(v, {4, 2, 5}), [2]f32{200, 0}), "the top-right corner, near")
	testing.expect(t, _near(_pixel(v, {4, 2, -500}), [2]f32{200, 0}), "the top-right corner, far")
	testing.expect(t, _near(_pixel(v, {-2, -1, 0}), [2]f32{50, 75}), "a point halfway to the bottom-left")
	testing.expect_value(t, engine.camera_half_height_at(cam, 1), f32(2))
	testing.expect_value(t, engine.camera_half_height_at(cam, 100), f32(2))

	// Every ray of the view is parallel, starting where its pixel is.
	r := engine.camera_screen_ray(cam, {150, 50}, {200, 100})
	testing.expect(t, _near(r.direction, [3]f32{0, 0, -1}), "a ray looks down -Z")
	testing.expect(t, _near(r.origin.xy, [2]f32{2, 0}), "a ray starts at its pixel")
	testing.expect(t, abs(r.origin.z - (10 - cam.near_clip)) < 0.001, "a ray starts on the near plane")
}

@(test)
test_perspective_camera_shrinks_with_distance :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	cam := _camera()
	cam.fov = 90
	v := engine.camera_render_view(cam, 200, 100)

	// At 90 degrees the view is as high as it is far: at distance 10 (the
	// origin) it is 20 high, at 20 it is 40 high.
	testing.expect(t, _near(_pixel(v, {20, 10, 0}), [2]f32{200, 0}), "the corner at distance 10")
	testing.expect(t, _near(_pixel(v, {20, 10, -10}), [2]f32{150, 25}), "the same point farther away is nearer the middle")
	testing.expect(t, abs(engine.camera_half_height_at(cam, 10) - 10) < 0.001, "half the height at distance 10")
}
