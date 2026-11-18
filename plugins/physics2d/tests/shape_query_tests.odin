package physics2d_tests

// physics2d's overlap and shape cast queries: what a circle, box or capsule
// touches, and the first collider one hits when it moves, through triggers
// and an ignored object, limited to layers.

import "core:math"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."

@(private = "file")
_square :: proc(name: string, pos: [2]f32, layers: u32 = 1, parent := engine.Transform_Handle{}, trigger := false) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = {pos.x, pos.y, 0}
	_, raw := engine.transform_add_comp(tH, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)raw
	box.enabled = true
	box.size = {1, 1}
	box.density = 1
	box.layers = layers
	box.is_trigger = trigger
	return tH
}

@(private = "file")
_has :: proc(list: []engine.Transform_Handle, tH: engine.Transform_Handle) -> bool {
	for o in list do if o == tH do return true
	return false
}

@(test)
test_overlap_2d_lists_what_a_shape_touches :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	testing.expect_value(t, len(physics2d.overlap_circle({}, 5)), 0) // before the first step

	LAYER_B :: u32(1 << 3)
	near := _square("Near", {1, 0})
	far := _square("Far", {4, 0})
	other := _square("Other", {-1, 0}, LAYER_B)
	trigger := _square("Trigger", {0, 1}, trigger = true)
	owner := engine.transform_new("Owner")
	own := _square("Own", {0, -1}, parent = owner)
	physics2d.physics_step(1.0 / 60.0)

	all := physics2d.overlap_circle({}, 1)
	testing.expect(t, _has(all, near) && _has(all, other) && _has(all, own), "a circle at the origin touches the three squares around it")
	testing.expect(t, !_has(all, far), "and not the far one")
	testing.expect(t, !_has(all, trigger), "a trigger is left out")

	layer := physics2d.overlap_circle({}, 1, layers = LAYER_B)
	testing.expect(t, len(layer) == 1 && layer[0] == other, "layers limit what is listed")
	ignored := physics2d.overlap_circle({}, 1, ignore = owner)
	testing.expect(t, !_has(ignored, own) && _has(ignored, near), "an ignored object's children are left out")

	long := physics2d.overlap_box({2.5, 0}, {1.4, 0.1})
	testing.expect(t, _has(long, near) && _has(long, far), "a box along X touches both squares on it")
	turned := physics2d.overlap_box({2.5, 0}, {1.4, 0.1}, angle = 90)
	testing.expectf(t, len(turned) == 0, "turned upright it touches neither: %v", len(turned))

	cap := physics2d.overlap_capsule({1, 2}, {4, 2}, 0.2)
	testing.expect_value(t, len(cap), 0)
	cap = physics2d.overlap_capsule({1, 0.6}, {4, 0.6}, 0.2)
	testing.expect(t, _has(cap, near) && _has(cap, far) && len(cap) == 2, "a capsule lying on the two squares touches both")
}

@(test)
test_shape_cast_2d_hits_what_a_ray_misses :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	caster := engine.transform_new("Caster")
	_square("Own", {1, 0.8}, parent = caster)
	_square("Trigger", {2, 0.8}, trigger = true)
	crate := _square("Crate", {5, 0.8})
	physics2d.physics_step(1.0 / 60.0)

	_, ray := physics2d.raycast({0, 0}, {1, 0}, 20, ignore = caster)
	testing.expect(t, !ray, "the ray passes under the crate")
	hit, ok := physics2d.circle_cast({0, 0}, 0.5, {2, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "the circle hits it, through the trigger and its own collider")
	testing.expectf(t, math.abs(hit.distance - 4.1) < 0.02, "it moved %v", hit.distance)
	testing.expectf(t, math.abs(hit.point.x - 4.5) < 0.02 && math.abs(hit.point.y - 0.3) < 0.02, "and touches at %v", hit.point)

	_, ok = physics2d.circle_cast({0, 0}, 0.5, {1, 0}, 3, ignore = caster)
	testing.expect(t, !ok, "not within 3 units")
	_, ok = physics2d.circle_cast({0, 0}, 0.5, {1, 0}, 20, layers = 1 << 5, ignore = caster)
	testing.expect(t, !ok, "not on another layer")

	hit, ok = physics2d.box_cast({0, 0.8}, {0.5, 0.5}, {1, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "a box hits it")
	testing.expectf(t, math.abs(hit.distance - 4) < 0.02, "face to face after 4 units, got %v", hit.distance)

	hit, ok = physics2d.capsule_cast({0, 0.5}, {0, 1.5}, 0.25, {1, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "a capsule hits it")
	testing.expectf(t, math.abs(hit.distance - 4.25) < 0.02, "its side reaches the crate after 4.25 units, got %v", hit.distance)

	hit, ok = physics2d.circle_cast({5, 0.8}, 0.2, {1, 0}, 20)
	testing.expectf(t, ok && hit.object == crate && hit.distance == 0 && hit.normal == {}, "a cast that starts inside a collider hits it at distance 0, with no normal: %v", hit)
}
