package physics2d_tests

// End-to-end physics2d package test: authored components -> box2d sync ->
// step -> transform write-back, through the same path the app takes.
// Ships WITH the package (docs/Plugins.md) — run_tests.sh runs every
// packages/*/tests suite after the central one.

import "core:testing"
import "../../../engine"
import common "../../../tests/common"
import physics2d ".."

@(test)
physics2d_dynamic_body_falls_onto_static_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Floor: box collider with NO rigidbody = implicit static body.
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {20, 1}
	box.density = 1
	box.friction = 0.6

	// Ball: dynamic rigidbody + circle collider, dropped from y = 3.
	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true
	circle.radius = 0.5
	circle.density = 1
	circle.friction = 0.6

	// ~3.3 sim seconds at 60 Hz — plenty to fall 5m and settle.
	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	// Floor top edge is at -1.5; the resting ball center is ≈ -1.0.
	testing.expect(t, y < 0, "ball should have fallen from y=3")
	testing.expect(t, y > -1.6, "ball should rest ON the floor, not fall through")

	// Escape hatch resolves the live body.
	_, ok := physics2d.body_of(ball)
	testing.expect(t, ok, "body_of should find the live body")
}

@(test)
physics2d_transform_scale_affects_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1x1 floor collider scaled 40x wide: only an effective 40x1 shape can
	// catch a ball dropped at x = 3 (the unscaled half-width is 0.5).
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	ft.scale = {40, 1, 1}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true

	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {3, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true

	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "scaled floor should catch the ball at x=3")
}

@(test)
physics2d_kinematic_body_pushes_dynamic :: proc(t: ^testing.T) {
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
	_, prb_ptr := engine.transform_add_comp(pusher, .Rigidbody2D)
	prb := cast(^physics2d.Rigidbody2D)prb_ptr
	prb.enabled = true
	prb.body_type = .Kinematic
	_, pbox_ptr := engine.transform_add_comp(pusher, .BoxCollider2D)
	pbox := cast(^physics2d.BoxCollider2D)pbox_ptr
	pbox.enabled = true

	// Dynamic crate ahead on +x, gravity off so it can only move by contact.
	crate := engine.transform_new("Crate")
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(crate))
	ct.position = {1.2, 0, 0}
	_, crb_ptr := engine.transform_add_comp(crate, .Rigidbody2D)
	crb := cast(^physics2d.Rigidbody2D)crb_ptr
	crb.enabled = true
	crb.body_type = .Dynamic
	crb.gravity_scale = 0
	_, cbox_ptr := engine.transform_add_comp(crate, .BoxCollider2D)
	cbox := cast(^physics2d.BoxCollider2D)cbox_ptr
	cbox.enabled = true

	// Drive the pusher 2 m/s along +x for one second of sim time.
	dt :: f32(1.0 / 60.0)
	for _ in 0 ..< 60 {
		pt = engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
		pt.position.x += 2 * dt
		physics2d.physics_step(dt)
	}

	x := engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position.x
	// Pusher front face ends at 2.5; the crate center must sit past 3.0
	// minus a small solver margin.
	testing.expect(t, x > 2.8, "kinematic pusher should shove the dynamic crate along +x")
}
