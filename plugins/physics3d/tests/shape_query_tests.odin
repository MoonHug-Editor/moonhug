package physics3d_tests

// physics3d's overlap and shape cast queries: what a sphere, box or capsule
// touches, and the first collider one hits when it moves, through triggers
// and an ignored object, limited to layers.

import "core:math"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."

@(private = "file")
_cube :: proc(name: string, pos: [3]f32, layers: u32 = 1, parent := engine.Transform_Handle{}, trigger := false) -> engine.Transform_Handle {
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
_has :: proc(list: []engine.Transform_Handle, tH: engine.Transform_Handle) -> bool {
	for o in list do if o == tH do return true
	return false
}

@(test)
test_overlap_lists_what_a_shape_touches :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	testing.expect_value(t, len(physics3d.overlap_sphere({}, 5)), 0) // before the first step

	LAYER_B :: u32(1 << 3)
	near := _cube("Near", {1, 0, 0})
	far := _cube("Far", {4, 0, 0})
	other := _cube("Other", {-1, 0, 0}, LAYER_B)
	trigger := _cube("Trigger", {0, 1, 0}, trigger = true)
	owner := engine.transform_new("Owner")
	own := _cube("Own", {0, -1, 0}, parent = owner)
	// Two colliders on one object: listed once.
	_, raw := engine.transform_add_comp(near, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)raw
	sphere.enabled = true
	sphere.radius = 0.5
	sphere.density = 1
	sphere.layers = 1
	physics3d.physics_step(1.0 / 60.0)

	all := physics3d.overlap_sphere({}, 1)
	testing.expect(t, _has(all, near) && _has(all, other) && _has(all, own), "a sphere at the origin touches the three cubes around it")
	testing.expect(t, !_has(all, far), "and not the far one")
	testing.expect(t, !_has(all, trigger), "a trigger is left out")
	count := 0
	for o in all do if o == near do count += 1
	testing.expect_value(t, count, 1)

	layer := physics3d.overlap_sphere({}, 1, layers = LAYER_B)
	testing.expect(t, len(layer) == 1 && layer[0] == other, "layers limit what is listed")
	ignored := physics3d.overlap_sphere({}, 1, ignore = owner)
	testing.expect(t, !_has(ignored, own) && _has(ignored, near), "an ignored object's children are left out")

	// A thin box along X reaches the far cube, the same box turned to Z does not.
	long := physics3d.overlap_box({2.5, 0, 0}, {1.4, 0.1, 0.1})
	testing.expect(t, _has(long, near) && _has(long, far), "a box along X touches both cubes on it")
	turned := physics3d.overlap_box({2.5, 0, 0}, {1.4, 0.1, 0.1}, rotation = engine.quat_from_euler_xyz(0, 90, 0))
	testing.expectf(t, len(turned) == 0, "turned to Z it touches neither: %v", len(turned))

	cap := physics3d.overlap_capsule({1, 2, 0}, {4, 2, 0}, 0.2)
	testing.expect_value(t, len(cap), 0)
	cap = physics3d.overlap_capsule({1, 0.6, 0}, {4, 0.6, 0}, 0.2)
	testing.expect(t, _has(cap, near) && _has(cap, far) && len(cap) == 2, "a capsule lying on the two cubes touches both")
}

@(test)
test_shape_cast_hits_what_a_ray_misses :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	caster := engine.transform_new("Caster")
	_cube("Own", {1, 0.8, 0}, parent = caster)
	_cube("Trigger", {2, 0.8, 0}, trigger = true)
	crate := _cube("Crate", {5, 0.8, 0})
	physics3d.physics_step(1.0 / 60.0)

	// The crate spans y 0.3 to 1.3: a ray along y = 0 passes under it, a
	// sphere of radius 0.5 on the same line does not.
	_, ray := physics3d.raycast({0, 0, 0}, {1, 0, 0}, 20, ignore = caster)
	testing.expect(t, !ray, "the ray passes under the crate")
	hit, ok := physics3d.sphere_cast({0, 0, 0}, 0.5, {2, 0, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "the sphere hits it, through the trigger and its own collider")
	// It touches the bottom-left edge (4.5, 0.3): centre 0.4 before it.
	testing.expectf(t, math.abs(hit.distance - 4.1) < 0.02, "it moved %v", hit.distance)
	testing.expectf(t, math.abs(hit.point.x - 4.5) < 0.02 && math.abs(hit.point.y - 0.3) < 0.02, "and touches at %v", hit.point)

	_, ok = physics3d.sphere_cast({0, 0, 0}, 0.5, {1, 0, 0}, 3, ignore = caster)
	testing.expect(t, !ok, "not within 3 units")
	_, ok = physics3d.sphere_cast({0, 0, 0}, 0.5, {1, 0, 0}, 20, layers = 1 << 5, ignore = caster)
	testing.expect(t, !ok, "not on another layer")

	hit, ok = physics3d.box_cast({0, 0.8, 0}, {0.5, 0.5, 0.5}, {1, 0, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "a box hits it")
	testing.expectf(t, math.abs(hit.distance - 4) < 0.02, "face to face after 4 units, got %v", hit.distance)

	hit, ok = physics3d.capsule_cast({0, 0.5, 0}, {0, 1.5, 0}, 0.25, {1, 0, 0}, 20, ignore = caster)
	testing.expect(t, ok && hit.object == crate, "a capsule hits it")
	testing.expectf(t, math.abs(hit.distance - 4.25) < 0.02, "its side reaches the crate after 4.25 units, got %v", hit.distance)

	hit, ok = physics3d.sphere_cast({5, 0.8, 0}, 0.2, {1, 0, 0}, 20)
	testing.expectf(t, ok && hit.object == crate && hit.distance == 0 && hit.normal == {}, "a cast that starts inside a collider hits it at distance 0, with no normal: %v", hit)
}
