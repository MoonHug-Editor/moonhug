package engine_tests

// Frustum culling (libs/core/view_math.odin): the plane test, the world box of
// a moved box, and the mesh collector dropping what a culling view cannot see.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"

// A camera at the origin looking down -Z, 60 degree fov, near 0.1, far 100.
@(private = "file")
_view_down_minus_z :: proc() -> engine.Render_View {
	view := linalg.matrix4_look_at_f32({0, 0, 0}, {0, 0, -1}, {0, 1, 0})
	proj := gfx.matrix4_perspective_z01(math.to_radians(f32(60)), 1, 0.1, 100)
	return engine.render_view_make(view, proj, 100, 100, ~u32(0))
}

@(private = "file")
_box_visible :: proc(f: engine.Frustum, center: [3]f32, half: f32) -> bool {
	return engine.frustum_intersects_aabb(f, center - half, center + half)
}

@(test)
test_frustum_intersects_aabb :: proc(t: ^testing.T) {
	f := _view_down_minus_z().frustum
	testing.expect(t, _box_visible(f, {0, 0, -5}, 0.5), "a box straight ahead is visible")
	testing.expect(t, _box_visible(f, {0, 0, -0.1}, 0.5), "a box crossing the near plane is visible")
	testing.expect(t, _box_visible(f, {3, 0, -5}, 0.5), "a box crossing the right edge is visible")
	testing.expect(t, !_box_visible(f, {0, 0, 5}, 0.5), "a box behind the camera is culled")
	testing.expect(t, !_box_visible(f, {50, 0, -5}, 0.5), "a box far to the right is culled")
	testing.expect(t, !_box_visible(f, {0, 50, -5}, 0.5), "a box far above is culled")
	testing.expect(t, !_box_visible(f, {0, 0, -150}, 0.5), "a box past the far plane is culled")
}

@(test)
test_aabb_transform :: proc(t: ^testing.T) {
	// A 2 x 4 x 6 box, scaled by 2, turned 90 degrees about +Y (x takes the
	// old z extent), moved to (10, 0, 0).
	rot := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	m := linalg.matrix4_from_trs_f32({10, 0, 0}, rot, {2, 2, 2})
	lo, hi := engine.aabb_transform({-1, -2, -3}, {1, 2, 3}, m)
	near :: proc(a, b: [3]f32) -> bool {
		return linalg.length(a - b) < 1e-4
	}
	testing.expectf(t, near(lo, {4, -4, -2}), "world min %v", lo)
	testing.expectf(t, near(hi, {16, 4, 2}), "world max %v", hi)
}

@(test)
test_mesh_collector_culls_outside_view :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_render_cull.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// A unit box mesh in the cache: bounds are all the collector reads.
	guid := engine.Asset_GUID{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}
	key := engine.Mesh_Key{guid, 0}
	engine.mesh_cache[key] = engine.Mesh{guid = guid, aabb_min = {-0.5, -0.5, -0.5}, aabb_max = {0.5, 0.5, 0.5}}
	defer delete_key(&engine.mesh_cache, key)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	place :: proc(tc: ^TestCtx, root: engine.Transform_Handle, name: string, pos: [3]f32, guid: engine.Asset_GUID) -> engine.Transform_Handle {
		tH := engine.transform_new(name, root)
		if tr := engine.pool_get(&tc.world.transforms, engine.Handle(tH)); tr != nil do tr.position = pos
		_, mf := engine.transform_get_or_add_comp(tH, engine.MeshFilter)
		mf.mesh.guid = guid
		_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
		mr.enabled = true
		return tH
	}
	front := place(tc_mem, root, "Front", {0, 0, -5}, guid)
	place(tc_mem, root, "Behind", {0, 0, 5}, guid)
	place(tc_mem, root, "Aside", {50, 0, -5}, guid)

	meshes :: proc(view: engine.Render_View) -> [dynamic]engine.Transform_Handle {
		commands := make([dynamic]engine.Render_Command, 0, 8, context.temp_allocator)
		engine.render_collect_commands(view, &commands)
		owners := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
		for c in commands {
			if _, is_mesh := c.variant.(engine.Draw_Mesh); is_mesh do append(&owners, c.owner)
		}
		return owners
	}

	view := _view_down_minus_z()
	testing.expect_value(t, len(meshes(view)), 3) // culling is off unless the view asks

	view.cull = true
	seen := meshes(view)
	testing.expect_value(t, len(seen), 1)
	if len(seen) == 1 do testing.expect(t, seen[0] == front, "the mesh in front of the camera is the one kept")
}
