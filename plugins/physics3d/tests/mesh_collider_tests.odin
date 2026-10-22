package physics3d_tests

// MeshCollider: the convex hull of a mesh on a dynamic body, the triangles
// of a mesh on a static body, the MeshFilter fallback, and the rule that a
// non-convex mesh needs a static body. The mesh is the unit cube fixture,
// imported into a temporary asset folder so the test is headless.

import "core:os"
import "core:testing"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import common "moonhug:tests/common"
import physics3d ".."
import b3 "vendor:box3d"

@(private = "file")
_SRC_DIR :: "moonhug/tests/fixtures/_mesh_collider_tmp"

// A test asset folder with the cube, and the asset db on it. The caller
// tears both down.
@(private = "file")
_cube_setup :: proc(t: ^testing.T) -> (cube: engine.PPtr, ok: bool) {
	os.make_directory(_SRC_DIR)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/cube.glb", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the cube fixture")
	if rerr != nil do return {}, false
	path := _SRC_DIR + "/cube.glb"
	testing.expect(t, os.write_entire_file(path, bytes) == nil)
	// The import pipeline, so a missing artifact imports from the source.
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SRC_DIR)
	guid, gok := engine.asset_db_get_guid(path)
	testing.expect(t, gok, "the cube is in the asset db")
	if !gok do return {}, false
	return engine.PPtr{guid = engine.Asset_GUID(guid)}, true
}

@(private = "file")
_cube_teardown :: proc() {
	engine.asset_db_shutdown()
	common.remove_tree(_SRC_DIR)
	common.remove_tree(engine.library_dir())
}

@(private = "file")
_floor :: proc(size: [3]f32) -> engine.Transform_Handle {
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = size
	return floor
}

@(test)
physics3d_mesh_collider_convex_falls_onto_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	cube, ok := _cube_setup(t)
	defer _cube_teardown()
	if !ok do return
	_floor({20, 1, 20})

	// A dynamic unit cube, dropped from y = 3, through the hull of its mesh.
	body := engine.transform_new("Cube")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(body, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	rb.use_gravity = true
	_, mc_ptr := engine.transform_add_comp(body, .MeshCollider)
	mc := cast(^physics3d.MeshCollider)mc_ptr
	mc.enabled = true
	mc.convex = true
	mc.mesh = cube

	for _ in 0 ..< 200 do physics3d.physics_step(1.0 / 60.0)

	testing.expect(t, b3.Shape_IsValid(mc.shape), "the hull shape exists")
	testing.expect(t, !mc.build_failed, "the build did not fail")
	y := engine.pool_get(&tc.world.transforms, engine.Handle(body)).position.y
	// The floor's top is at -1.5 and the cube's half height is 0.5.
	testing.expectf(t, y > -1.1 && y < -0.9, "the cube rests on the floor, y = %v", y)
}

@(test)
physics3d_mesh_collider_static_triangles_catch_a_ball :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	cube, ok := _cube_setup(t)
	defer _cube_teardown()
	if !ok do return

	// The cube's triangles as a static floor, scaled to 20 x 1 x 20 through
	// the transform, with the mesh named by a MeshFilter and the collider's
	// own field empty.
	floor := engine.transform_new("MeshFloor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	ft.scale = {20, 1, 20}
	_, mf_ptr := engine.transform_add_comp(floor, .MeshFilter)
	(cast(^engine.MeshFilter)mf_ptr).mesh = cube
	_, mc_ptr := engine.transform_add_comp(floor, .MeshCollider)
	mc := cast(^physics3d.MeshCollider)mc_ptr
	mc.enabled = true
	mc.convex = false

	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {3, 3, 3}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	rb.use_gravity = true
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true
	sphere.radius = 0.5

	for _ in 0 ..< 200 do physics3d.physics_step(1.0 / 60.0)

	testing.expect(t, b3.Shape_IsValid(mc.shape), "the mesh shape exists")
	testing.expect(t, mc.mesh_data != nil, "the collider owns the triangles")
	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expectf(t, y > -1.1 && y < -0.9, "the ball rests on the mesh floor, y = %v", y)
}

@(test)
physics3d_mesh_collider_non_convex_needs_a_static_body :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	cube, ok := _cube_setup(t)
	defer _cube_teardown()
	if !ok do return

	body := engine.transform_new("Cube")
	_, rb_ptr := engine.transform_add_comp(body, .Rigidbody)
	(cast(^physics3d.Rigidbody)rb_ptr).enabled = true
	_, mc_ptr := engine.transform_add_comp(body, .MeshCollider)
	mc := cast(^physics3d.MeshCollider)mc_ptr
	mc.enabled = true
	mc.convex = false
	mc.mesh = cube

	physics3d.physics_step(1.0 / 60.0)
	testing.expect(t, mc.build_failed, "a non-convex mesh under a Rigidbody is refused")
	testing.expect(t, !b3.Shape_IsValid(mc.shape), "and builds no shape")

	// Reset clears the refusal, and convex builds on the next step.
	physics3d.reset_MeshCollider(mc)
	mc.enabled = true
	mc.convex = true
	mc.mesh = cube
	physics3d.physics_step(1.0 / 60.0)
	testing.expect(t, b3.Shape_IsValid(mc.shape), "the hull builds after the reset")
}
