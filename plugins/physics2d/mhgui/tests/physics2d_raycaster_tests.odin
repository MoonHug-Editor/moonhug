package physics2d_mhgui_tests

// Physics2DRaycaster (physics2d/mhgui): a 2D collider under the pointer is
// found where the camera's ray crosses the XY plane.

import "core:testing"
import "moonhug:packages/engine"
import mhgui "moonhug:packages/mhgui"
import physics2d "moonhug:packages/physics2d"
import physics2d_mhgui "moonhug:packages/physics2d/mhgui"
import common "moonhug:tests/common"

@(test)
test_pointer_finds_a_2d_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	viewport := [2]f32{800, 600}
	centre := [2]f32{400, 300}

	// A camera with a raycaster, placed so its ray through the middle of
	// the screen crosses the XY plane.
	cam_node := engine.transform_new("Camera")
	_, craw := engine.transform_add_comp(cam_node, .Camera)
	cam := cast(^engine.Camera)craw
	engine.type_reset_Camera(cam)
	cam.enabled = true
	_, rraw := engine.transform_add_comp(cam_node, .Physics2DRaycaster)
	caster := cast(^physics2d_mhgui.Physics2DRaycaster)rraw
	physics2d_mhgui.type_reset_Physics2DRaycaster(caster)
	caster.enabled = true
	// Back along its own view, so the plane is 10 in front of it.
	forward := engine.camera_screen_ray(cam, centre, viewport).direction
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(cam_node)).position = {0, 0, -forward.z * 10}
	ray := engine.camera_screen_ray(cam, centre, viewport)
	testing.expectf(t, abs(ray.direction.z) > 0.5, "the test's camera looks at the XY plane: %v", ray.direction)
	at := ray.origin + ray.direction * (-ray.origin.z / ray.direction.z)

	crate := engine.transform_new("Crate")
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(crate)).position = {at.x, at.y, 0}
	_, braw := engine.transform_add_comp(crate, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)braw
	box.enabled = true
	box.size = {1, 1}
	box.density = 1
	box.layers = 1
	physics2d.physics_step(1.0 / 60.0) // builds the bodies

	hit, found := physics2d_mhgui.pointer_raycast(centre, viewport)
	testing.expect(t, found && hit.node == crate, "the raycaster finds the crate under the pointer")
	testing.expect_value(t, hit.source, mhgui.Pointer_Source.World_2D)
	testing.expectf(t, abs(hit.point.x - at.x) < 0.01 && abs(hit.point.y - at.y) < 0.01 && hit.point.z == 0, "on the plane, under the pointer: %v", hit.point)

	// A corner of the screen is far from the crate.
	_, found = physics2d_mhgui.pointer_raycast({5, 5}, viewport)
	testing.expect(t, !found, "nothing under the corner")
	// A layer the raycaster does not look at.
	caster.layers = 2
	_, found = physics2d_mhgui.pointer_raycast(centre, viewport)
	testing.expect(t, !found, "the crate is on another layer")
}
