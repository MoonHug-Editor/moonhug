package physics3d_tests

// PhysicsRaycaster: a collider under the pointer gets pointer events through
// @(comp_on_pointer) procs. That UI in front of it gets them first is the
// pointer package's priority rule (engine/tests/pointer_tests.odin).

import "core:testing"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import pointer "moonhug:packages/engine/pointer"
import physics3d "moonhug:packages/physics3d"
import common "moonhug:tests/common"
import sdl "vendor:sdl3"

@(private = "file")
_Got :: struct {
	kind:   pointer.Pointer_Kind,
	node:   engine.Transform_Handle,
	source: pointer.Pointer_Source,
	point:  [3]f32,
}
@(private = "file") _got: [64]_Got
@(private = "file") _got_n: int

// What a game's component would do: here it keeps what it was sent.
@(private = "file")
_record :: proc(comp: rawptr, ev: ^pointer.Pointer_Event) {
	if _got_n < len(_got) {
		_got[_got_n] = {ev.kind, ev.node, ev.source, ev.world_position}
		_got_n += 1
	}
	if ev.kind == .Down do ev.used = true
}

@(private = "file")
_count :: proc(node: engine.Transform_Handle, kind: pointer.Pointer_Kind) -> (n: int) {
	for g in _got[:_got_n] do if g.node == node && g.kind == kind do n += 1
	return
}

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
test_pointer_reaches_a_collider :: proc(t: ^testing.T) {
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
	prev := pointer.procs[.BoxCollider]
	pointer.register(.BoxCollider, _record)
	defer pointer.register(.BoxCollider, prev)
	_got_n = 0
	viewport := [2]f32{800, 600}
	centre := [2]f32{400, 300}

	// A camera with a raycaster, and a box 5 units along its ray through
	// the middle of the screen.
	cam_node := engine.transform_new("Camera")
	_, craw := engine.transform_add_comp(cam_node, .Camera)
	cam := cast(^engine.Camera)craw
	engine.type_reset_Camera(cam)
	cam.enabled = true
	_, rraw := engine.transform_add_comp(cam_node, .PhysicsRaycaster)
	caster := cast(^physics3d.PhysicsRaycaster)rraw
	physics3d.type_reset_PhysicsRaycaster(caster)
	caster.enabled = true
	ray := engine.camera_screen_ray(cam, centre, viewport)
	crate := engine.transform_new("Crate")
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(crate)).position = ray.origin + ray.direction * 5
	_, braw := engine.transform_add_comp(crate, .BoxCollider)
	box := cast(^physics3d.BoxCollider)braw
	box.enabled = true
	box.size = {1, 1, 1}
	box.density = 1
	box.layers = 1
	physics3d.physics_step(1.0 / 60.0) // builds the bodies

	hit, found := physics3d.pointer_raycast(centre, viewport)
	testing.expect(t, found && hit.node == crate && hit.source == .World_3D, "the raycaster finds the crate under the pointer")
	testing.expectf(t, abs(hit.distance - 4.5) < 0.05, "at its near face: %v", hit.distance)

	// The pointer over it: Enter. A press and a release: Down, Up and Click,
	// each saying it came through a 3D collider and where it was hit.
	_frame(centre)
	testing.expect_value(t, _count(crate, .Enter), 1)
	testing.expect(t, !pointer.over(.UI), "a collider under the pointer is not UI")
	_frame(centre, down = true)
	_frame(centre, up = true)
	testing.expect_value(t, _count(crate, .Down), 1)
	testing.expect_value(t, _count(crate, .Up), 1)
	testing.expect_value(t, _count(crate, .Click), 1)
	for g in _got[:_got_n] do if g.kind == .Click {
		testing.expect_value(t, g.source, pointer.Pointer_Source.World_3D)
		testing.expectf(t, abs(linalg_length(g.point - (ray.origin + ray.direction * 4.5))) < 0.05, "the hit point is on the crate's near face: %v", g.point)
	}

	// Off the crate: Exit, and nothing more.
	_frame({50, 50})
	testing.expect_value(t, _count(crate, .Exit), 1)
	_frame({50, 50}, down = true)
	_frame({50, 50}, up = true)
	testing.expect_value(t, _count(crate, .Click), 1)

	// A layer the raycaster does not look at: the crate is not found.
	caster.layers = 2
	_, found = physics3d.pointer_raycast(centre, viewport)
	testing.expect(t, !found, "the crate is on another layer")
}

@(private = "file")
linalg_length :: proc(v: [3]f32) -> f32 {
	return abs(v.x) + abs(v.y) + abs(v.z)
}
