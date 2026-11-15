package tween_tests

// More to animate: world space, UI, camera and light fields, any component
// field, shake and punch, and the speed option.

import "core:testing"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"

@(private = "file")
_DT :: f32(1.0 / 64.0)

@(private = "file")
_tick :: proc(steps: int) {
	for _ in 0 ..< steps do tween.tick_all(_DT)
}

@(private = "file")
_tr :: proc(h: engine.Transform_Handle) -> ^engine.Transform {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
}

@(private = "file")
_near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-3
}

@(test)
test_world_space_and_speed :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	parent := engine.transform_new("Parent")
	_tr(parent).position = {10, 0, 0}
	child := engine.transform_new("Child", parent)

	// World: the child ends at the world point, whatever its parent is.
	tween.world_position(child, {12, 4, 0}, 0.5)
	_tick(33)
	got := engine.transform_world_position(child)
	testing.expect(t, _near(got.x, 12) && _near(got.y, 4))
	testing.expect(t, _near(_tr(child).position.x, 2), "the local position is relative to the parent")

	// Speed: 8 units at 4 per second take 2 seconds, whatever the duration says.
	_tr(child).position = {}
	h := tween.position(child, {8, 0, 0}, 99, opt = {speed = 4})
	_tick(64)
	testing.expect(t, _near(_tr(child).position.x, 4))
	testing.expect(t, tween.is_alive(h))
	_tick(65)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _tr(child).position, [3]f32{8, 0, 0})

	// An authored world move is a node like the others.
	a := tween.authored(tween.TweenMoveToWorld{position = {0, 0, 0}, duration = 0.25})
	defer tween.authored_destroy(&a)
	tween.complete(tween.run(&a, tween.TweenContext{subject = child}))
	got = engine.transform_world_position(child)
	testing.expect(t, _near(got.x, 0) && _near(got.y, 0))
}

@(test)
test_ui_camera_and_light_fields :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	ui := engine.transform_new("Panel")
	_, rect_raw := engine.transform_add_comp(ui, .RectTransform)
	rect := cast(^engine.RectTransform)rect_raw
	_, cr_raw := engine.transform_add_comp(ui, .CanvasRenderer)
	cr := cast(^engine.CanvasRenderer)cr_raw
	rect.anchored_position = {}
	rect.size_delta = {}

	tween.anchored_position(ui, {100, 50, 0}, 0.5)
	tween.size_delta(ui, {200, 80}, 0.5)
	tween.ui_alpha(ui, 0, 0.5)
	_tick(16)
	testing.expect(t, _near(rect.anchored_position.x, 50) && _near(rect.anchored_position.y, 25))
	testing.expect(t, _near(rect.size_delta.x, 100))
	testing.expect(t, cr.tinted && _near(cr.tint.a, 0.5), "an untinted graphic fades from white")
	testing.expect_value(t, cr.tint.rgb, [3]f32{1, 1, 1})
	_tick(17)
	testing.expect_value(t, rect.anchored_position, [3]f32{100, 50, 0})
	testing.expect_value(t, rect.size_delta, [2]f32{200, 80})
	testing.expect_value(t, cr.tint.a, f32(0))

	cam_obj := engine.transform_new("Camera")
	_, cam_raw := engine.transform_add_comp(cam_obj, .Camera)
	camera := cast(^engine.Camera)cam_raw
	camera.fov = 60
	_, light_raw := engine.transform_add_comp(cam_obj, .Light)
	light := cast(^engine.Light)light_raw
	light.intensity = 1
	light.color = {1, 1, 1, 1}

	tween.camera_fov(cam_obj, 40, 0.5)
	tween.light_intensity(cam_obj, 3, 0.5)
	tween.light_color(cam_obj, {1, 0, 0}, 0.5)
	_tick(33)
	testing.expect_value(t, camera.fov, f32(40))
	testing.expect_value(t, light.intensity, f32(3))
	testing.expect_value(t, light.color, [4]f32{1, 0, 0, 1})

	// A component that goes away ends the tween: nothing points at it.
	h := tween.camera_fov(cam_obj, 90, 1)
	_tick(4)
	engine.transform_destroy(cam_obj)
	_tick(1)
	testing.expect(t, !tween.is_alive(h))
}

@(test)
test_shake_and_punch_return_to_the_start :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	_tr(a).position = {5, 5, 5}
	start_rotation := _tr(a).rotation

	tween.shake_position(a, {1, 1, 0}, 0.5)
	tween.punch_scale(a, {0.5, 0.5, 0.5}, 0.5)
	tween.shake_rotation(a, {0, 0, 20}, 0.5)

	moved, bounded := false, true
	for _ in 0 ..< 30 {
		_tick(1)
		p := _tr(a).position
		if abs(p.x - 5) > 0.01 || abs(p.y - 5) > 0.01 do moved = true
		if abs(p.x - 5) > 1.001 || abs(p.y - 5) > 1.001 || p.z != 5 do bounded = false
	}
	testing.expect(t, moved, "a shake moves the object")
	testing.expect(t, bounded, "a shake stays within its strength and off axes without strength")

	_tick(4)
	testing.expect_value(t, tween.run_count(), 0)
	testing.expect_value(t, _tr(a).position, [3]f32{5, 5, 5})
	testing.expect_value(t, _tr(a).scale, [3]f32{1, 1, 1})
	r := _tr(a).rotation
	testing.expect(t, _near(r.x, start_rotation.x) && _near(r.y, start_rotation.y) && _near(r.z, start_rotation.z) && _near(r.w, start_rotation.w))
}
