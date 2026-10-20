package physics3d_tests

// Physics materials (physics_material.odin): the combine rules, the defaults
// of a collider with none, and a material reaching the solver.

import "core:encoding/uuid"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."
import b3 "vendor:box3d"

@(private = "file")
_id :: proc(friction_combine, bounce_combine: physics3d.Material_Combine) -> u64 {
	s: b3.SurfaceMaterial
	physics3d.material_apply(&s, {friction_combine = friction_combine, bounce_combine = bounce_combine})
	return s.userMaterialId
}

@(test)
physics3d_material_combine :: proc(t: ^testing.T) {
	avg, mn, mul, mx := _id(.Average, .Average), _id(.Minimum, .Minimum), _id(.Multiply, .Multiply), _id(.Maximum, .Maximum)
	testing.expect_value(t, physics3d.material_combine(0.2, avg, 0.8, avg, false), f32(0.5))
	testing.expect_value(t, physics3d.material_combine(0.2, mn, 0.8, mn, false), f32(0.2))
	testing.expect_value(t, physics3d.material_combine(0.5, mul, 0.8, mul, false), f32(0.4))
	testing.expect_value(t, physics3d.material_combine(0.2, mx, 0.8, mx, false), f32(0.8))
	// The higher-ranked mode of the two wins, and a shape with no material is Average.
	testing.expect_value(t, physics3d.material_combine(0.2, avg, 0.8, mx, false), f32(0.8))
	testing.expect_value(t, physics3d.material_combine(0.25, mn, 0.5, mul, false), f32(0.125))
	testing.expect_value(t, physics3d.material_combine(0.2, 0, 0.8, 0, false), f32(0.5))
	// Friction and bounce modes are separate.
	split := _id(.Minimum, .Maximum)
	testing.expect_value(t, physics3d.material_combine(0.2, split, 0.8, split, false), f32(0.2))
	testing.expect_value(t, physics3d.material_combine(0.2, split, 0.8, split, true), f32(0.8))
	d := physics3d.material_of({})
	testing.expect_value(t, d.friction, f32(0.6))
	testing.expect_value(t, d.bounciness, f32(0))
}

// The settings' default material is what a collider gets when it names none.
@(test)
physics3d_default_material_setting :: proc(t: ^testing.T) {
	g := engine.Asset_GUID(uuid.read("8c2f5e01-71a3-4b9d-8e44-1f0a6b3c9d73") or_else uuid.Identifier{})
	physics3d.material_preview(g, {friction = 0.9, bounciness = 0.5})
	prev := physics3d.physics3d_settings.default_material
	defer physics3d.physics3d_settings.default_material = prev
	physics3d.physics3d_settings.default_material = g
	testing.expect_value(t, physics3d.material_of({}).friction, f32(0.9))
	physics3d.physics3d_settings.default_material = {}
	testing.expect_value(t, physics3d.material_of({}).friction, f32(0.6))
}

// A ball on a bouncy material comes back up after it hits the floor, one with
// none stays down.
@(test)
physics3d_material_bounces_ball :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bouncy := engine.Asset_GUID(uuid.read("6a1e3c55-0d6e-4f1a-9a77-3b2c1d0e9f01") or_else uuid.Identifier{})
	physics3d.material_preview(bouncy, {friction = 0.6, bounciness = 1, bounce_combine = .Maximum})

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {40, 1, 40}

	drop :: proc(tc: ^common.TestCtx, x: f32, material: engine.Asset_GUID) -> engine.Transform_Handle {
		ball := engine.transform_new("Ball")
		engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position = {x, 3, 0}
		_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
		(cast(^physics3d.Rigidbody)rb_ptr).enabled = true
		_, sp := engine.transform_add_comp(ball, .SphereCollider)
		s := cast(^physics3d.SphereCollider)sp
		s.enabled = true
		s.radius = 0.5
		s.material = material
		return ball
	}
	plain := drop(tc, -5, {})
	springy := drop(tc, 5, bouncy)

	low := [2]f32{100, 100}
	peak_after := [2]f32{-100, -100}
	for _ in 0 ..< 240 {
		physics3d.physics_step(1.0 / 60.0)
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
