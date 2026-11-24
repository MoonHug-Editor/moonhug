package physics2d_sample_tests

// MachinePoke on a body made here: the pointer over its collider lights its
// look, and a click pushes the body. The camera's Physics2DRaycaster is what
// finds the collider.

import "core:testing"
import "moonhug:libs/input"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import physics2d "moonhug:packages/physics2d"
import sample "moonhug:packages/physics2d_sample"
import sprites "moonhug:packages/sprites"
import common "moonhug:tests/common"
import b2 "vendor:box2d"
import sdl "vendor:sdl3"

// One frame with the mouse at a viewport point, the left button going down or up.
@(private = "file")
_frame :: proc(pos: [2]f32, down := false, up := false) {
	input.frame_reset()
	e: sdl.Event
	e.type = .MOUSE_MOTION
	e.motion.x, e.motion.y = pos.x, pos.y
	input.apply_event(&e)
	if down || up {
		b: sdl.Event
		b.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
		b.button.button = 1
		b.button.down = down
		b.button.x, b.button.y = pos.x, pos.y
		input.apply_event(&b)
	}
	pointer.pointer_update(0)
}

@(test)
test_machine_poke_lights_and_pushes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	input.set_app_focused(true)
	defer input.set_app_focused(false)
	input.set_viewport({0, 0}, {800, 600})
	pointer.reset()
	defer pointer.reset()
	w := engine.ctx_world()
	viewport := [2]f32{800, 600}
	centre := [2]f32{400, 300}

	// A camera with a raycaster, back along its own view so the XY plane is
	// 10 in front of it.
	cam_node := engine.transform_new("Camera")
	_, craw := engine.transform_add_comp(cam_node, .Camera)
	cam := cast(^engine.Camera)craw
	engine.type_reset_Camera(cam)
	cam.enabled = true
	_, rraw := engine.transform_add_comp(cam_node, .Physics2DRaycaster)
	caster := cast(^physics2d.Physics2DRaycaster)rraw
	physics2d.type_reset_Physics2DRaycaster(caster)
	caster.enabled = true
	forward := engine.camera_screen_ray(cam, centre, viewport).direction
	engine.pool_get(&w.transforms, engine.Handle(cam_node)).position = {0, 0, -forward.z * 10}
	ray := engine.camera_screen_ray(cam, centre, viewport)
	at := ray.origin + ray.direction * (-ray.origin.z / ray.direction.z)

	// A balloon under the middle of the screen: a body, a collider, a sprite
	// and the poke.
	balloon := engine.transform_new("Balloon")
	engine.pool_get(&w.transforms, engine.Handle(balloon)).position = {at.x, at.y, 0}
	_, rb_raw := engine.transform_add_comp(balloon, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_raw
	rb.enabled = true
	rb.use_auto_mass = true
	_, c_raw := engine.transform_add_comp(balloon, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)c_raw
	circle.enabled = true
	circle.radius = 0.5
	circle.density = 1
	circle.layers = 1
	sprite_owned, s_raw := engine.transform_add_comp(balloon, .SpriteRenderer)
	sprite := cast(^sprites.SpriteRenderer)s_raw
	sprite.enabled = true
	sprite.color = {1, 0, 0, 1}
	_, p_raw := engine.transform_add_comp(balloon, .MachinePoke)
	poke := cast(^sample.MachinePoke)p_raw
	sample.type_reset_MachinePoke(poke)
	poke.enabled = true
	poke.look.handle = sprite_owned.handle
	physics2d.physics_step(1.0 / 60.0) // builds the body

	_frame({5, 5})
	testing.expect_value(t, sprite.color, [4]f32{1, 0, 0, 1})
	_frame(centre)
	testing.expect_value(t, sprite.color, poke.hover_color) // Enter
	_frame(centre, down = true)
	_frame(centre, up = true)
	body, ok := physics2d.body_of(balloon)
	testing.expect(t, ok, "the balloon has a body")
	testing.expect_value(t, b2.Body_GetLinearVelocity(body), poke.push) // Click
	_frame({5, 5})
	testing.expect_value(t, sprite.color, [4]f32{1, 0, 0, 1}) // Exit
}
