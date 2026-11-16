package physics3d_tests

// physics3d.raycast: the closest collider along a ray, through triggers and
// an ignored object, limited to layers and a distance.

import "core:math"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."

@(private = "file")
_box :: proc(name: string, pos: [3]f32, layers: u32, parent := engine.Transform_Handle{}, trigger := false) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = pos
	_, raw := engine.transform_add_comp(tH, .BoxCollider)
	box := cast(^physics3d.BoxCollider)raw
	box.enabled = true
	box.size = {1, 1, 1}
	box.density = 1
	box.layers = layers
	box.is_trigger = trigger
	return tH
}

@(private = "file")
_near :: proc(a, b: f32) -> bool {
	return math.abs(a - b) < 0.01
}

@(test)
test_raycast_hits_the_closest_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	LAYER_A :: u32(1 << 0)
	LAYER_B :: u32(1 << 3)
	caster := engine.transform_new("Caster")
	own := _box("Own", {-10, 0, 0}, LAYER_A, parent = caster)
	trigger := _box("Trigger", {-5, 0, 0}, LAYER_A, trigger = true)
	crate := _box("Crate", {2, 0, 0}, LAYER_A)
	wall := _box("Wall", {5, 0, 0}, LAYER_B)
	_ = own
	_ = trigger
	physics3d.physics_step(1.0 / 60.0) // builds the bodies

	// The ray starts before the caster's own collider and crosses it.
	origin := [3]f32{-12, 0, 0}
	right := [3]f32{1, 0, 0}

	// Through the caster's own collider, which it ignores, and the trigger,
	// onto the crate: the closest of crate and wall.
	hit, ok := physics3d.raycast(origin, right, 100, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "the crate, the closest")
	testing.expectf(t, _near(hit.point.x, 1.5) && _near(hit.distance, 13.5), "at the crate's near face, got %v at %v", hit.point, hit.distance)
	testing.expectf(t, _near(hit.normal.x, -1), "the face's normal points back along the ray, got %v", hit.normal)

	// Only layer B: past the crate, onto the wall.
	hit, ok = physics3d.raycast(origin, right * 3, 100, layers = LAYER_B, ignore = caster)
	testing.expect(t, ok && hit.object == wall && _near(hit.point.x, 4.5), "the wall, the crate is on another layer")

	// Too short to reach anything past the caster.
	_, ok = physics3d.raycast(origin, right, 7, ignore = caster)
	testing.expect(t, !ok, "nothing within 5")

	// Nothing ignored: the caster's own collider is the first hit.
	hit, ok = physics3d.raycast(origin, right, 100)
	testing.expect(t, ok && hit.object == own && _near(hit.point.x, -10.5), "the caster's own collider when nothing is ignored")

	// A ray pointing nowhere hits nothing.
	_, ok = physics3d.raycast(origin, {}, 100)
	testing.expect(t, !ok, "a zero direction")
}
