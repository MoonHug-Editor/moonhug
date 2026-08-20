package physics3d_tests

// End-to-end physics3d package test: authored components -> box3d sync ->
// step -> transform write-back, through the same path the app takes.

import "core:testing"
import "moonhug:engine"
import common "moonhug:tests/common"
import physics3d ".."

@(test)
physics3d_dynamic_body_falls_onto_static_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Floor: box collider with NO rigidbody = implicit static body.
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {20, 1, 20}
	box.density = 1
	box.friction = 0.6

	// Ball: dynamic rigidbody + sphere collider, dropped from y = 3.
	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	rb.use_gravity = true
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true
	sphere.radius = 0.5
	sphere.density = 1
	sphere.friction = 0.6

	// ~3.3 sim seconds at 60 Hz — plenty to fall 5m and settle.
	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	// Floor top face is at -1.5; the resting ball center is ≈ -1.0.
	testing.expect(t, y < 0, "ball should have fallen from y=3")
	testing.expect(t, y > -1.6, "ball should rest ON the floor, not fall through")

	// Escape hatch resolves the live body.
	_, ok := physics3d.body_of(ball)
	testing.expect(t, ok, "body_of should find the live body")
}

@(test)
physics3d_transform_scale_affects_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1x1x1 floor collider scaled 40x wide: only an effective 40x1x40 shape
	// can catch a ball dropped at x = 3 (the unscaled half-width is 0.5).
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	ft.scale = {40, 1, 40}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true

	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {3, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true

	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "scaled floor should catch the ball at x=3")
}

@(test)
physics3d_kinematic_body_pushes_dynamic :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Kinematic pusher moved via its TRANSFORM (the script-driven pattern).
	// Velocity-driven follow makes the step carry it into the crate — a
	// teleporting follow would never impart momentum.
	pusher := engine.transform_new("Pusher")
	pt := engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
	pt.position = {0, 0, 0}
	_, prb_ptr := engine.transform_add_comp(pusher, .Rigidbody)
	prb := cast(^physics3d.Rigidbody)prb_ptr
	prb.enabled = true
	prb.is_kinematic = true
	_, pbox_ptr := engine.transform_add_comp(pusher, .BoxCollider)
	pbox := cast(^physics3d.BoxCollider)pbox_ptr
	pbox.enabled = true

	// Dynamic crate ahead on +x, gravity off so it can only move by contact.
	crate := engine.transform_new("Crate")
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(crate))
	ct.position = {1.2, 0, 0}
	_, crb_ptr := engine.transform_add_comp(crate, .Rigidbody)
	crb := cast(^physics3d.Rigidbody)crb_ptr
	crb.enabled = true
	crb.use_gravity = false
	_, cbox_ptr := engine.transform_add_comp(crate, .BoxCollider)
	cbox := cast(^physics3d.BoxCollider)cbox_ptr
	cbox.enabled = true

	// Drive the pusher 2 m/s along +x for one second of sim time.
	dt :: f32(1.0 / 60.0)
	for _ in 0 ..< 60 {
		pt = engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
		pt.position.x += 2 * dt
		physics3d.physics_step(dt)
	}

	x := engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position.x
	// Pusher front face ends at 2.5; the crate center must sit past 3.0
	// minus a small solver margin.
	testing.expect(t, x > 2.8, "kinematic pusher should shove the dynamic crate along +x")
}
