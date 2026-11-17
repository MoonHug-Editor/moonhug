package physics2d_tests

// CharacterController2D (physics2d/character_controller_2d.odin): moves
// without going through colliders, walks up gentle slopes and low steps,
// stops at walls and steep slopes, walks through triggers. Each test builds a
// little world in code and walks a capsule 2 high with its feet at the
// object's position.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."

// A static box `size` big at `pos`, turned `tilt` degrees.
@(private = "file")
_block :: proc(name: string, pos, size: [2]f32, tilt: f32 = 0, trigger := false) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	t.position = {pos.x, pos.y, 0}
	t.rotation = engine.quat_from_native(linalg.quaternion_angle_axis_f32(math.to_radians(tilt), {0, 0, 1}))
	_, raw := engine.transform_add_comp(tH, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)raw
	box.enabled = true
	box.size = size
	box.density = 1
	box.layers = 1
	box.is_trigger = trigger
	return tH
}

// A ramp 20 long and 1 thick rising at `tilt` degrees from the floor's top
// at x = 2.
@(private = "file")
_ramp :: proc(name: string, tilt: f32) {
	r := math.to_radians(tilt)
	along := [2]f32{math.cos(r), math.sin(r)}
	up := [2]f32{-math.sin(r), math.cos(r)}
	_block(name, [2]f32{2, 0} + along * 10 - up * 0.5, {20, 1}, tilt)
}

@(private = "file")
_floor :: proc() {
	_block("Floor", {0, -0.5}, {60, 1})
}

@(private = "file")
_player :: proc(pos: [2]f32) -> ^physics2d.CharacterController2D {
	tH := engine.transform_new("Player")
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = {pos.x, pos.y, 0}
	_, raw := engine.transform_add_comp(tH, .CharacterController2D)
	cc := cast(^physics2d.CharacterController2D)raw
	cc.enabled = true
	cc.offset = {0, 1} // feet at the object's position
	return cc
}

@(private = "file")
_at :: proc(cc: ^physics2d.CharacterController2D) -> [2]f32 {
	return engine.transform_world(cc.owner).position.xy
}

@(private = "file")
_walk :: proc(cc: ^physics2d.CharacterController2D, across: f32, frames: int) {
	for _ in 0 ..< frames do physics2d.character_move(cc, {across, -0.1})
}

@(test)
test_character_2d_lands_stops_at_a_wall_and_passes_a_trigger :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_block("Trigger", {2, 1}, {1, 2}, trigger = true)
	_block("Wall", {6, 1}, {1, 2}) // its near face at x = 5.5
	cc := _player({0, 1})
	physics2d.physics_step(1.0 / 60)

	_walk(cc, 0, 30)
	testing.expectf(t, cc.is_grounded && abs(_at(cc).y) < 0.05, "lands on the floor: %v", _at(cc))

	_walk(cc, 0.1, 80)
	testing.expectf(t, abs(_at(cc).x - 5.0) < 0.05, "walks through the trigger and stops at the wall: x %v", _at(cc).x)
	flags := physics2d.character_move(cc, {0.1, -0.1})
	testing.expectf(t, .Sides in flags && .Below in flags, "touching the wall, on the floor: %v", flags)
}

@(test)
test_character_2d_steps_and_slopes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_block("Low step", {-6, 0.1}, {2, 0.2}) // top at 0.2, faces at -7 and -5
	_block("High step", {-12, 0.25}, {2, 0.5}) // top at 0.5, faces at -13 and -11
	_ramp("Gentle", 30)
	cc := _player({-3, 0.05})
	physics2d.physics_step(1.0 / 60)
	_walk(cc, 0, 5)

	// Left: up the low step, over it, down, and stopped by the high one.
	_walk(cc, -0.1, 25)
	testing.expectf(t, abs(_at(cc).y - 0.2) < 0.05, "walks up onto the 0.2 step: %v", _at(cc))
	_walk(cc, -0.1, 60)
	testing.expectf(t, abs(_at(cc).x - -10.5) < 0.1 && _at(cc).y < 0.05, "stops at the 0.5 step: %v", _at(cc))

	// Right: up the 30 degree ramp, then standing still on it.
	_walk(cc, 0.1, 200)
	testing.expectf(t, _at(cc).y > 2 && cc.is_grounded, "walks up a 30 degree slope: %v", _at(cc))
	stand := _at(cc)
	_walk(cc, 0, 60)
	testing.expectf(t, linalg.length(_at(cc) - stand) < 0.02, "stands still on it: %v from %v", _at(cc), stand)
}

@(test)
test_character_2d_does_not_climb_a_steep_slope :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	_ramp("Steep", 60)
	cc := _player({0, 0.05})
	physics2d.physics_step(1.0 / 60)
	_walk(cc, 0, 5)
	_walk(cc, 0.1, 60)
	testing.expectf(t, _at(cc).y < 0.6, "does not walk up a 60 degree slope: %v", _at(cc))
}

@(test)
test_character_2d_capsule_is_in_the_world :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_floor()
	cc := _player({0, 0})
	physics2d.physics_step(1.0 / 60)
	hit, ok := physics2d.raycast({-5, 1}, {1, 0}, 10)
	testing.expectf(t, ok && hit.object == cc.owner && abs(hit.point.x + 0.5) < 0.02, "a ray hits the controller's capsule: %v", hit)
}
