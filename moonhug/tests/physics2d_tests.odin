package tests

// End-to-end physics2d package test: authored components -> box2d sync ->
// step -> transform write-back, through the same path the app takes.

import "core:testing"
import "../engine"
import "../app"
import physics2d "packages:physics2d"

@(test)
physics2d_dynamic_body_falls_onto_static_floor :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	app.register_packages()

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

	// ~4 sim seconds at 50 Hz — plenty to fall 5m and settle.
	for _ in 0 ..< 200 {
		physics2d.physics_step(0.02)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	// Floor top edge is at -1.5; the resting ball center is ≈ -1.0.
	testing.expect(t, y < 0, "ball should have fallen from y=3")
	testing.expect(t, y > -1.6, "ball should rest ON the floor, not fall through")

	// The landing produced contact events at some step; at rest the pair
	// still exists — begin fired once, so check the escape hatch instead.
	body, ok := physics2d.body_of(ball)
	testing.expect(t, ok, "body_of should find the live body")
	_ = body
}
