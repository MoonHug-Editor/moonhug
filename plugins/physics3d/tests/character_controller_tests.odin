package physics3d_tests

// CharacterController (physics3d/character_controller.odin): moves without
// going through colliders, walks up gentle slopes and low steps, stops at
// walls and steep slopes, stands still on a slope, follows the ground down.
// Each test builds a little world in code and walks a capsule 2 high with its
// feet at the object's position.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."

// A static box `size` big at `pos`, turned `tilt` degrees about Z: a ramp
// rising along +X for a positive tilt.
@(private = "file")
_block :: proc(name: string, pos, size: [3]f32, tilt: f32 = 0) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	t.position = pos
	t.rotation = engine.quat_from_native(linalg.quaternion_angle_axis_f32(math.to_radians(tilt), {0, 0, 1}))
	_, raw := engine.transform_add_comp(tH, .BoxCollider)
	box := cast(^physics3d.BoxCollider)raw
	box.enabled = true
	box.size = size
	box.density = 1
	box.layers = 1
	return tH
}

// A ramp 20 long, 3 wide and 1 thick at z `z`, rising along +X at `tilt`
// degrees from the floor's top at x = 2.
@(private = "file")
_ramp :: proc(name: string, z, tilt: f32) {
	r := math.to_radians(tilt)
	along := [2]f32{math.cos(r), math.sin(r)}
	up := [2]f32{-math.sin(r), math.cos(r)}
	mid := [2]f32{2, 0} + along * 10 - up * 0.5
	_block(name, {mid.x, mid.y, z}, {20, 1, 3}, tilt)
}

// The ground: a floor whose top is y = 0.
@(private = "file")
_floor :: proc() {
	_block("Floor", {0, -0.5, 0}, {40, 1, 40})
}

@(private = "file")
_player :: proc(pos: [3]f32) -> ^physics3d.CharacterController {
	tH := engine.transform_new("Player")
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = pos
	_, raw := engine.transform_add_comp(tH, .CharacterController)
	cc := cast(^physics3d.CharacterController)raw
	cc.enabled = true
	cc.center = {0, 1, 0} // feet at the object's position
	return cc
}

@(private = "file")
_at :: proc(cc: ^physics3d.CharacterController) -> [3]f32 {
	return engine.transform_world(cc.owner).position
}

// `frames` moves of `per_frame` across plus a fall, as a game makes them.
@(private = "file")
_walk :: proc(cc: ^physics3d.CharacterController, per_frame: [3]f32, frames: int) {
	for _ in 0 ..< frames do physics3d.character_move(cc, per_frame + {0, -0.1, 0})
}

@(private = "file")
_setup :: proc(tc: ^common.TestCtx) {
	common.setup(tc)
}

@(test)
test_character_lands_and_stops_at_a_wall :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	_setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_block("Wall", {3, 1, 0}, {1, 2, 4}) // its near face at x = 2.5
	cc := _player({0, 1, 0})
	physics3d.physics_step(1.0 / 60) // builds the bodies

	_walk(cc, {}, 30)
	testing.expectf(t, cc.is_grounded && .Below in cc.collision_flags, "lands on the floor")
	testing.expectf(t, abs(_at(cc).y) < 0.05, "its feet on the floor's top: %v", _at(cc).y)

	_walk(cc, {0.1, 0, 0}, 40)
	testing.expectf(t, abs(_at(cc).x - 2.0) < 0.05, "stops with its side at the wall: x %v", _at(cc).x)
	testing.expect(t, cc.is_grounded, "still on the floor")
	flags := physics3d.character_move(cc, {0.1, -0.1, 0})
	testing.expectf(t, .Sides in flags, "says it touches something across: %v", flags)

	// Into the wall at an angle: it slides along it.
	z := _at(cc).z
	_walk(cc, {0.1, 0, 0.1}, 10)
	testing.expectf(t, _at(cc).z > z + 0.8 && _at(cc).x < 2.05, "slides along the wall: %v", _at(cc))
}

@(test)
test_character_walks_up_a_low_step_and_not_a_high_one :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	_setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_block("Low step", {3, 0.1, -3}, {2, 0.2, 2}) // top at 0.2, under step_offset 0.3
	_block("High step", {3, 0.25, 3}, {2, 0.5, 2}) // top at 0.5
	low := _player({0, 0.05, -3})
	high := _player({0, 0.05, 3})
	physics3d.physics_step(1.0 / 60)
	_walk(low, {}, 5)
	_walk(high, {}, 5)

	_walk(low, {0.1, 0, 0}, 30)
	testing.expectf(t, _at(low).x > 2.5 && abs(_at(low).y - 0.2) < 0.05, "walks up onto the 0.2 step: %v", _at(low))
	testing.expect(t, low.is_grounded, "and stands on it")

	_walk(high, {0.1, 0, 0}, 30)
	testing.expectf(t, _at(high).x < 1.55 && _at(high).y < 0.05, "stops at the 0.5 step: %v", _at(high))
}

@(test)
test_character_on_slopes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	_setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_ramp("Gentle", -4, 30)
	_ramp("Steep", 4, 60)
	gentle := _player({0, 0.05, -4})
	steep := _player({0, 0.05, 4})
	physics3d.physics_step(1.0 / 60)
	_walk(gentle, {}, 5)
	_walk(steep, {}, 5)

	_walk(gentle, {0.1, 0, 0}, 60)
	testing.expectf(t, _at(gentle).y > 1.5 && gentle.is_grounded, "walks up a 30 degree slope: %v", _at(gentle))
	testing.expectf(t, abs(gentle.ground_normal.y - math.cos(math.to_radians(f32(30)))) < 0.02, "on ground tilted 30 degrees: %v", gentle.ground_normal)

	// Standing on it with gravity: it stays where it is.
	stand := _at(gentle)
	_walk(gentle, {}, 60)
	testing.expectf(t, linalg.length(_at(gentle) - stand) < 0.02, "stands still on the slope: %v from %v", _at(gentle), stand)

	// Down again: on the ground every frame, no hops.
	airborne := 0
	for _ in 0 ..< 40 {
		physics3d.character_move(gentle, {-0.1, -0.1, 0})
		if !gentle.is_grounded do airborne += 1
	}
	testing.expectf(t, airborne == 0, "walks down it on the ground, %v frames in the air", airborne)

	_walk(steep, {0.1, 0, 0}, 60)
	testing.expectf(t, _at(steep).y < 0.6, "does not walk up a 60 degree slope: %v", _at(steep))
}

@(test)
test_character_slides_down_a_steep_slope :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	_setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_block("Steep", {0, 2, 0}, {10, 1, 3}, 60)
	cc := _player({-0.5, 6, 0})
	physics3d.physics_step(1.0 / 60)
	_walk(cc, {}, 20)
	start := _at(cc)
	_walk(cc, {}, 30)
	testing.expectf(t, _at(cc).y < start.y - 0.3 && !cc.is_grounded, "slides down it: %v from %v", _at(cc), start)
}

@(test)
test_character_capsule_is_in_the_world :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	_setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	cc := _player({0, 0, 0})
	physics3d.physics_step(1.0 / 60)
	hit, ok := physics3d.raycast({-5, 1, 0}, {1, 0, 0}, 10)
	testing.expect(t, ok && hit.object == cc.owner, "a ray hits the controller's capsule")
	testing.expectf(t, abs(hit.point.x + 0.5) < 0.02, "at its side: %v", hit.point)

	// Its body follows the object on the next step.
	physics3d.character_move(cc, {2, 0, 0})
	physics3d.physics_step(1.0 / 60)
	hit, ok = physics3d.raycast({-5, 1, 0}, {1, 0, 0}, 10)
	testing.expectf(t, ok && abs(hit.point.x - 1.5) < 0.05, "where the object went: %v", hit.point)
}
