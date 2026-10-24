package physics3d_tests

// Convex decompositions a model lists in its import settings, on a U: each
// set is computed after the import, a Rigidbody carries the hulls one shape
// each, a reimport computes only the sets that changed, a fresh clone takes
// them from the meta, a cancelled set waits for its Compute, and sets run
// side by side. The fixture is a closed U, 3 x 3 x 1 around its origin, two
// posts on a bar.
//
// Only the first test runs the real CoACD tool, which checks its flags and
// the hulls it makes. It skips when mh setup has not built CoACD, which
// mh test reports after the summary. The others test the editor's job
// handling with a stand-in that writes the U's three hulls at once
// (fake_coacd.sh), so the suite never waits for a decomposition. Each test
// starts with no job state: the teardown resets it.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import common "moonhug:tests/common"
import "moonhug:editor/tasks"
import physics3d ".."
import physics3d_editor "moonhug:packages/physics3d/editor"
import b3 "vendor:box3d"

@(private = "file")
_SRC_DIR :: "moonhug/tests/fixtures/_mesh_decomposition_tmp"
@(private = "file")
_GUID :: "6b1f3c52-2d0e-4c55-9a43-7b9e8d2f4a10"
// Set ids are random, as engine.mesh_new_sub_id mints them.
@(private = "file") _SET_A :: engine.Local_ID(0x3f1d8a2b7c4e5f61)
@(private = "file") _SET_B :: engine.Local_ID(0x12c0ffee4d5a6b77)
@(private = "file") _FAKE_COACD :: "plugins/physics3d/tests/fake_coacd.sh"

// The U's meta with these sets, written before the asset db reads it.
@(private = "file")
_write_meta :: proc(t: ^testing.T, sets: []engine.Mesh_Hull_Set) {
	list := ""
	for s, i in sets {
		list = fmt.tprintf("%s%s{{\"id\": %d, \"part\": %d, \"max_hulls\": %d, \"concavity\": %v}}", list, "" if i == 0 else ", ", s.id, s.part, s.max_hulls, s.concavity)
	}
	meta := fmt.tprintf(`{{"guid": "%s", "importer": "mesh", "settings": {{"__type_guid": "fadd5659-ad40-4e00-95c7-908efc8e8631", "scale": 1, "hull_sets": [%s]}}}}`, _GUID, list)
	testing.expect(t, os.write_entire_file(_SRC_DIR + "/u_shape.gltf.meta", transmute([]byte)meta) == nil)
}

@(private = "file")
_u_setup :: proc(t: ^testing.T, sets: []engine.Mesh_Hull_Set) -> (guid: engine.Asset_GUID, ok: bool) {
	os.make_directory(_SRC_DIR)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/u_shape.gltf", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the U fixture")
	if rerr != nil do return {}, false
	testing.expect(t, os.write_entire_file(_SRC_DIR + "/u_shape.gltf", bytes) == nil)
	_write_meta(t, sets)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SRC_DIR)
	g, gok := engine.asset_db_get_guid(_SRC_DIR + "/u_shape.gltf")
	testing.expect(t, gok, "the U is in the asset db")
	if !gok do return {}, false
	// The editor's startup import pass: the import's reimport hook queues the sets.
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(_SRC_DIR + "/u_shape.gltf"), "the U imports")
	return engine.Asset_GUID(g), true
}

@(private = "file")
_u_teardown :: proc() {
	physics3d_editor.hull_jobs_reset()
	engine.asset_db_shutdown()
	common.remove_tree(_SRC_DIR)
	common.remove_tree(engine.library_dir())
}

@(test)
physics3d_decomposition_carries_a_u :: proc(t: ^testing.T) {
	if !os.exists(physics3d_editor.COACD_EXE) {
		common.skip(t, "CoACD is not built, mh setup builds it")
		return
	}
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	guid, ok := _u_setup(t, {{id = _SET_A, part = 0, max_hulls = 8, concavity = 0.05}})
	defer _u_teardown()
	if !ok do return

	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	(cast(^physics3d.BoxCollider)box_ptr).size = {20, 1, 20}

	// Upright, bar down, at y = 2.
	body := engine.transform_new("U")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {0, 2, 0}
	_, rb_ptr := engine.transform_add_comp(body, .Rigidbody)
	(cast(^physics3d.Rigidbody)rb_ptr).use_gravity = true
	_, mc_ptr := engine.transform_add_comp(body, .MeshCollider)
	mc := cast(^physics3d.MeshCollider)mc_ptr
	mc.mesh = engine.PPtr{guid = guid}
	mc.convex = true
	mc.hull_set = _SET_A
	// The set is also a sub-asset of the model.
	_, is_set := engine.mesh_hull_set_of(engine.PPtr{guid = guid, local_id = _SET_A})
	testing.expect(t, is_set, "a reference to the set names a convex decomposition")
	fresh := engine.mesh_new_sub_id(guid)
	testing.expect(t, fresh > 0 && fresh != _SET_A, "a new sub-asset id is positive and unused")

	// The import queued the set. Until it is computed the world holds still,
	// and the step returns at once.
	_, state := physics3d.mesh_hulls(guid, _SET_A)
	testing.expect(t, state == .Pending, "the import queued the set")
	for _ in 0 ..< 10 do physics3d.physics_step(1.0 / 60.0)
	testing.expectf(t, engine.pool_get(&tc.world.transforms, engine.Handle(body)).position.y == 2, "the U waits for its hulls")
	testing.expect(t, !mc.build_failed, "a pending set is no failure")

	physics3d_editor.hull_jobs_wait()
	hulls, ready := physics3d.mesh_hulls(guid, _SET_A)
	testing.expect(t, ready == .Ready, "the set is computed")
	for h in hulls {
		testing.expect(t, len(h) >= 4 && len(h) <= physics3d.HULL_MAX_VERTICES, "a hull has 4 to HULL_MAX_VERTICES points")
		lo, hi := h[0], h[0]
		for p in h do lo, hi = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}, {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		testing.expectf(t, lo.x > -1.55 && hi.x < 1.55 && lo.y > -1.55 && hi.y < 1.55 && lo.z > -0.55 && hi.z < 0.55, "a hull lies in the U's bounds, %v to %v", lo, hi)
		// The gap between the posts is x in (-0.5, 0.5) above y = -0.5.
		testing.expectf(t, !(lo.x < -0.3 && hi.x > 0.3 && hi.y > 0.3), "no hull spans the gap, %v to %v", lo, hi)
	}

	for _ in 0 ..< 180 do physics3d.physics_step(1.0 / 60.0)
	testing.expectf(t, len(mc.shapes) >= 3 && len(mc.shapes) <= 8, "a U is at least its bar and two posts, got %d shapes", len(mc.shapes))
	for sh in mc.shapes do testing.expect(t, b3.Shape_GetType(sh) == .hullShape, "each hull is a shape")
	// The floor's top is at -1.5 and the U's half height is 1.5.
	y := engine.pool_get(&tc.world.transforms, engine.Handle(body)).position.y
	testing.expectf(t, y > -0.1 && y < 0.1, "the U stands on the floor, y = %v", y)

	// A set of the whole model on a collider of its part: the hulls are in
	// another mesh's space, so it builds nothing and says so.
	parts := engine.mesh_parts(guid)
	testing.expect(t, len(parts) == 1, "the U has one part")
	if len(parts) != 1 do return
	mc2_owner := engine.transform_new("U2")
	_, mc2_ptr := engine.transform_add_comp(mc2_owner, .MeshCollider)
	mc2 := cast(^physics3d.MeshCollider)mc2_ptr
	mc2.mesh = engine.PPtr{guid = guid, local_id = parts[0].id}
	mc2.convex = true
	mc2.hull_set = _SET_A
	physics3d.physics_step(1.0 / 60.0)
	testing.expect(t, mc2.build_failed, "a set of another mesh fails the build")
}

// Two sets, then the second one's values change through Apply: the hulls
// of the first come back from the meta at once, and only the second is
// computed again. Apply keeps the meta's hulls.
@(test)
physics3d_decomposition_recomputes_only_changed_sets :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	physics3d_editor.coacd_exe = _FAKE_COACD
	defer physics3d_editor.coacd_exe = physics3d_editor.COACD_EXE
	guid, ok := _u_setup(t, {{id = _SET_A, part = 0, max_hulls = 8, concavity = 0.05}, {id = _SET_B, part = 0, max_hulls = 3, concavity = 0.05}})
	defer _u_teardown()
	if !ok do return
	physics3d_editor.hull_jobs_wait()
	first_old, _ := physics3d.mesh_hulls_path(guid, _SET_A)
	first_old = fmt.aprintf("%s", first_old, allocator = context.temp_allocator)
	testing.expect(t, os.exists(first_old), "the first set is computed")

	path := _SRC_DIR + "/u_shape.gltf"
	settings, sok := engine.asset_pipeline_get_settings(path, context.temp_allocator)
	testing.expect(t, sok, "reads the U's settings")
	if !sok do return
	ms := cast(^engine.MeshSettings)settings.data
	ms.hull_sets[1].max_hulls = 4 // _SET_B
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(path, settings), "Apply writes the meta")
	saved, has := asset_pipeline.asset_meta_value(path, physics3d_editor.META_HULLS_KEY, context.temp_allocator)
	testing.expect(t, has && len(saved.(json.Array)) == 2, "and keeps both sets' hulls in it")
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(path), "the changed settings reimport the U")

	first_new, _ := physics3d.mesh_hulls_path(guid, _SET_A)
	testing.expect(t, first_new != first_old, "the reimport moved the model to a new key")
	testing.expect(t, os.exists(first_new), "the unchanged set comes back from the meta at once")
	testing.expect(t, !physics3d.mesh_hulls_pending(guid, _SET_A), "and queues nothing")
	testing.expect(t, physics3d.mesh_hulls_pending(guid, _SET_B), "the changed set queues")
	physics3d_editor.hull_jobs_wait()
	_, state := physics3d.mesh_hulls(guid, _SET_B)
	testing.expect(t, state == .Ready, "the changed set is computed")
}

// A fresh clone has the model and its meta but no library: every set comes
// back from the meta, and nothing is computed.
@(test)
physics3d_decomposition_fresh_clone_computes_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	physics3d_editor.coacd_exe = _FAKE_COACD
	defer physics3d_editor.coacd_exe = physics3d_editor.COACD_EXE
	guid, ok := _u_setup(t, {{id = _SET_A, part = 0, max_hulls = 8, concavity = 0.05}})
	defer _u_teardown()
	if !ok do return
	physics3d_editor.hull_jobs_wait()

	engine.asset_db_shutdown()
	common.remove_tree(engine.library_dir())
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SRC_DIR)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(_SRC_DIR + "/u_shape.gltf"), "the clone imports the U")
	testing.expect(t, !physics3d.mesh_hulls_pending(guid, _SET_A), "nothing queues")
	hulls, state := physics3d.mesh_hulls(guid, _SET_A)
	testing.expectf(t, state == .Ready && len(hulls) >= 3, "the hulls come from the meta, %v", state)
}

// A cancelled set stays without hulls, even across a reconcile, until its
// Compute queues it again.
@(test)
physics3d_decomposition_cancel_and_compute :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	physics3d_editor.coacd_exe = _FAKE_COACD
	defer physics3d_editor.coacd_exe = physics3d_editor.COACD_EXE
	guid, ok := _u_setup(t, {{id = _SET_A, part = 0, max_hulls = 8, concavity = 0.05}})
	defer _u_teardown()
	if !ok do return

	physics3d_editor.hull_set_cancel(guid, _SET_A)
	state, _ := physics3d_editor.hull_set_state(guid, _SET_A)
	testing.expectf(t, state == .Cancelled, "the set is cancelled, %v", state)
	physics3d_editor.hull_sets_reconcile(guid)
	testing.expect(t, !physics3d.mesh_hulls_pending(guid, _SET_A), "a reconcile leaves a cancelled set alone")
	_, hstate := physics3d.mesh_hulls(guid, _SET_A)
	testing.expect(t, hstate == .Missing, "a cancelled set has no hulls")

	physics3d_editor.hull_set_compute(guid, _SET_A)
	testing.expect(t, physics3d.mesh_hulls_pending(guid, _SET_A), "Compute queues it again")
	physics3d_editor.hull_jobs_wait()
	state, _ = physics3d_editor.hull_set_state(guid, _SET_A)
	testing.expectf(t, state == .Ready, "and it is computed, %v", state)
}

// With two decompositions allowed at once, two sets run side by side, each
// with its own line in the status bar.
@(test)
physics3d_decomposition_runs_sets_side_by_side :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	physics3d_editor.coacd_exe = _FAKE_COACD
	defer physics3d_editor.coacd_exe = physics3d_editor.COACD_EXE
	before := physics3d.physics3d_settings.decompositions_at_once
	defer physics3d.physics3d_settings.decompositions_at_once = before
	physics3d.physics3d_settings.decompositions_at_once = 2
	guid, ok := _u_setup(t, {{id = _SET_A, part = 0, max_hulls = 8, concavity = 0.05}, {id = _SET_B, part = 0, max_hulls = 3, concavity = 0.05}})
	defer _u_teardown()
	if !ok do return

	lines := tasks.collect() // the status bar's call, which starts queued jobs
	a, _ := physics3d_editor.hull_set_state(guid, _SET_A)
	b, _ := physics3d_editor.hull_set_state(guid, _SET_B)
	testing.expectf(t, a == .Running && b == .Running, "both sets run, %v and %v", a, b)
	testing.expectf(t, len(lines) == 2, "one status line each, got %d", len(lines))
	physics3d_editor.hull_jobs_wait()
	_, sa := physics3d.mesh_hulls(guid, _SET_A)
	_, sb := physics3d.mesh_hulls(guid, _SET_B)
	testing.expect(t, sa == .Ready && sb == .Ready, "and both are computed")
}
