package physics2d_tests

// Physics materials (physics_material.odin): the combine rules, the defaults
// of a collider with none, and a material reaching the solver.

import "core:encoding/uuid"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."
import b2 "vendor:box2d"

@(private = "file")
_id :: proc(friction_combine, bounce_combine: physics2d.Material_Combine2D) -> i32 {
	s: b2.SurfaceMaterial
	physics2d.material_apply(&s, {friction_combine = friction_combine, bounce_combine = bounce_combine})
	return s.userMaterialId
}

@(test)
physics2d_material_combine :: proc(t: ^testing.T) {
	avg, mean, mul, mn, mx := _id(.Average, .Average), _id(.Mean, .Mean), _id(.Multiply, .Multiply), _id(.Minimum, .Minimum), _id(.Maximum, .Maximum)
	testing.expect_value(t, physics2d.material_combine(0.2, avg, 0.8, avg, false), f32(0.5))
	testing.expect_value(t, physics2d.material_combine(0.25, mean, 1, mean, false), f32(0.5))
	testing.expect_value(t, physics2d.material_combine(0.25, mul, 0.5, mul, false), f32(0.125))
	testing.expect_value(t, physics2d.material_combine(0.2, mn, 0.8, mn, false), f32(0.2))
	testing.expect_value(t, physics2d.material_combine(0.2, mx, 0.8, mx, false), f32(0.8))
	// The 2D rank: Maximum > Minimum > Multiply > Mean > Average.
	testing.expect_value(t, physics2d.material_combine(0.25, mn, 0.5, mul, false), f32(0.25))
	testing.expect_value(t, physics2d.material_combine(0.25, mul, 1, mean, false), f32(0.25))
	testing.expect_value(t, physics2d.material_combine(0.25, mean, 1, avg, false), f32(0.5))
	testing.expect_value(t, physics2d.material_combine(0.2, mn, 0.8, mx, false), f32(0.8))
	// A shape with no material mixes as box2d does: Mean friction, Maximum bounce.
	testing.expect_value(t, physics2d.material_combine(0.25, 0, 1, 0, false), f32(0.5))
	testing.expect_value(t, physics2d.material_combine(0.2, 0, 0.8, 0, true), f32(0.8))
	// Friction and bounce modes are separate.
	split := _id(.Minimum, .Maximum)
	testing.expect_value(t, physics2d.material_combine(0.2, split, 0.8, split, false), f32(0.2))
	testing.expect_value(t, physics2d.material_combine(0.2, split, 0.8, split, true), f32(0.8))
	d := physics2d.material_of({})
	testing.expect_value(t, d.friction, f32(0.4))
	testing.expect_value(t, d.bounciness, f32(0))
	testing.expect_value(t, d.friction_combine, physics2d.Material_Combine2D.Mean)
	testing.expect_value(t, d.bounce_combine, physics2d.Material_Combine2D.Maximum)
}

// The settings' default material is what a collider gets when neither it nor
// its Rigidbody2D names one.
@(test)
physics2d_default_material_setting :: proc(t: ^testing.T) {
	g := engine.Asset_GUID(uuid.read("8c2f5e01-71a3-4b9d-8e44-1f0a6b3c9d72") or_else uuid.Identifier{})
	physics2d.material_preview(g, {friction = 0.9, bounciness = 0.5, friction_combine = .Minimum, bounce_combine = .Average})
	prev := physics2d.physics2d_settings.default_material
	defer physics2d.physics2d_settings.default_material = prev
	physics2d.physics2d_settings.default_material = g
	testing.expect_value(t, physics2d.material_of({}).friction, f32(0.9))
	physics2d.physics2d_settings.default_material = {}
	testing.expect_value(t, physics2d.material_of({}).friction, f32(0.4))
}

// A ball whose Rigidbody2D names a bouncy material comes back up after it
// hits the floor, one with none stays down.
@(test)
physics2d_material_bounces_ball :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bouncy := engine.Asset_GUID(uuid.read("6a1e3c55-0d6e-4f1a-9a77-3b2c1d0e9f01") or_else uuid.Identifier{})
	physics2d.material_preview(bouncy, {friction = 0.6, bounciness = 1, bounce_combine = .Maximum})

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {40, 1}

	drop :: proc(tc: ^common.TestCtx, x: f32, material: engine.Asset_GUID) -> engine.Transform_Handle {
		ball := engine.transform_new("Ball")
		engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position = {x, 3, 0}
		// The collider names no material: the Rigidbody2D's applies.
		_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
		rb := cast(^physics2d.Rigidbody2D)rb_ptr
		rb.enabled = true
		rb.body_type = .Dynamic
		rb.material = material
		_, cp := engine.transform_add_comp(ball, .CircleCollider2D)
		c := cast(^physics2d.CircleCollider2D)cp
		c.enabled = true
		c.radius = 0.5
		return ball
	}
	plain := drop(tc, -5, {})
	springy := drop(tc, 5, bouncy)

	low := [2]f32{100, 100}
	peak_after := [2]f32{-100, -100}
	for _ in 0 ..< 240 {
		physics2d.physics_step(1.0 / 60.0)
		for b, i in ([2]engine.Transform_Handle{plain, springy}) {
			y := engine.pool_get(&tc.world.transforms, engine.Handle(b)).position.y
			if y < low[i] {
				low[i] = y
				peak_after[i] = y
			} else {
				peak_after[i] = max(peak_after[i], y)
			}
		}
	}
	testing.expectf(t, peak_after[0] < low[0] + 0.3, "the plain ball stays down (low %v, peak after %v)", low[0], peak_after[0])
	testing.expectf(t, peak_after[1] > low[1] + 2, "the bouncy ball comes back up (low %v, peak after %v)", low[1], peak_after[1])
}
