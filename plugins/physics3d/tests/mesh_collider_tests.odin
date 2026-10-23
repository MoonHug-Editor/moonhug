package physics3d_tests

// MeshCollider: the convex hull of a mesh on a dynamic body, the triangles
// of a mesh on a static body, the MeshFilter fallback, and the rule that a
// non-convex mesh needs a static body. The mesh is the unit cube fixture,
// imported into a temporary asset folder so the test is headless.

import "core:encoding/uuid"
import "core:math"
import "core:math/rand"
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

// The hull cap fits a dense mesh: box3d returns no hull above it, so the
// cap is what makes a real model's collider build.
@(test)
physics3d_hull_cap_fits_a_dense_mesh :: proc(t: ^testing.T) {
	pts := make([][3]f32, 4000, context.temp_allocator)
	for &p in pts {
		u := rand.float32() * 2 - 1
		th := rand.float32() * 2 * math.PI
		r := math.sqrt(1 - u * u)
		p = {r * math.cos(th), r * math.sin(th), u}
	}
	h := b3.CreateHull(raw_data(pts), i32(len(pts)), physics3d.HULL_MAX_VERTICES)
	testing.expect(t, h != nil, "a dense sphere cloud builds a hull at the cap")
	if h == nil do return
	defer b3.DestroyHull(h)
	testing.expect(t, h.vertexCount <= physics3d.HULL_MAX_VERTICES, "reduced to the cap")
}

// A dense mesh: the helmet model of 15k triangles. box3d keeps 256
// triangles per contact, so without the chunking a box over the shell falls
// through it. With it, boxes rest on the shell at its top plus their half
// height. The balls that a dome sends rolling are not the test.
@(test)
physics3d_mesh_collider_dense_mesh_holds_a_box :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init("moonhug/packages/app/assets/meshes/DamagedHelmet")
	defer { engine.asset_db_shutdown(); common.remove_tree(engine.library_dir()) }
	guid, gok := engine.asset_db_get_guid("moonhug/packages/app/assets/meshes/DamagedHelmet/DamagedHelmet.gltf")
	testing.expect(t, gok, "the helmet is in the asset db")
	if !gok do return
	helmet := engine.transform_new("Helmet")
	_, mc_ptr := engine.transform_add_comp(helmet, .MeshCollider)
	mc := cast(^physics3d.MeshCollider)mc_ptr
	mc.mesh = engine.PPtr{guid = engine.Asset_GUID(guid)}
	_floor({20, 1, 20})

	sizes := [2]f32{0.3, 0.8}
	for size in sizes {
		body := engine.transform_new("Box")
		bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
		// Over the top of the dome, shell at y = 0.9 there.
		bt.position = {0.01, 2.5, -0.39}
		_, rb_ptr := engine.transform_add_comp(body, .Rigidbody)
		(cast(^physics3d.Rigidbody)rb_ptr).use_gravity = true
		_, bp := engine.transform_add_comp(body, .BoxCollider)
		(cast(^physics3d.BoxCollider)bp).size = {size, size, size}
		for _ in 0 ..< 300 do physics3d.physics_step(1.0 / 60.0)
		y := engine.pool_get(&tc.world.transforms, engine.Handle(body)).position.y
		testing.expectf(t, y > 0.9 + size * 0.5 - 0.05 && y < 0.9 + size * 0.5 + 0.1, "a %v box rests on the shell, y = %v", size, y)
		engine.transform_destroy(body)
	}
	testing.expect(t, b3.Shape_GetType(mc.shape) == .compoundShape, "a dense mesh is a compound of chunks")
}

// A material edit while the simulation runs reaches a MeshCollider on the
// next step: a hull takes it in place, a compound of mesh chunks is built
// again with it.
@(test)
physics3d_mesh_collider_material_edit :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init("moonhug/packages/app/assets/meshes/DamagedHelmet")
	defer { engine.asset_db_shutdown(); common.remove_tree(engine.library_dir()) }
	guid, gok := engine.asset_db_get_guid("moonhug/packages/app/assets/meshes/DamagedHelmet/DamagedHelmet.gltf")
	testing.expect(t, gok, "the helmet is in the asset db")
	if !gok do return

	material := engine.Asset_GUID(uuid.read("3d9a6f12-5b0e-4c71-8a2d-6e4f1b7c0a95") or_else uuid.Identifier{})
	physics3d.material_preview(material, {friction = 0.2})

	add :: proc(name: string, mesh: engine.Asset_GUID, convex: bool, material: engine.Asset_GUID) -> ^physics3d.MeshCollider {
		h := engine.transform_new(name)
		_, mc_ptr := engine.transform_add_comp(h, .MeshCollider)
		mc := cast(^physics3d.MeshCollider)mc_ptr
		mc.mesh = engine.PPtr{guid = mesh}
		mc.convex = convex
		mc.material = material
		return mc
	}
	hull := add("Hull", engine.Asset_GUID(guid), true, material)
	shell := add("Shell", engine.Asset_GUID(guid), false, material)

	physics3d.physics_step(1.0 / 60.0)
	testing.expect_value(t, b3.Shape_GetSurfaceMaterial(hull.shape).friction, f32(0.2))
	testing.expect(t, shell.compound != nil, "a dense mesh is a compound of chunks")
	testing.expect_value(t, shell.compound_material.friction, f32(0.2))

	physics3d.material_preview(material, {friction = 0.9})
	physics3d.physics_step(1.0 / 60.0)
	testing.expect_value(t, b3.Shape_GetSurfaceMaterial(hull.shape).friction, f32(0.9))
	testing.expect(t, b3.Shape_IsValid(shell.shape), "the compound is built again in the same step")
	testing.expect_value(t, shell.compound_material.friction, f32(0.9))

	// An edit of another material leaves this surface as it is and keeps the
	// compound.
	kept := shell.compound
	other := engine.Asset_GUID(uuid.read("7b21c4e8-90d3-4f5a-b6c1-2e8d4a9f3c07") or_else uuid.Identifier{})
	physics3d.material_preview(other, {friction = 0.5})
	physics3d.physics_step(1.0 / 60.0)
	testing.expect(t, shell.compound == kept, "an unchanged surface keeps the compound")
}
