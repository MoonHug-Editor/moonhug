package tests

import "../engine"
import "core:testing"
import "core:os"

// Verifies the Ref_Local picker assignment path: when the user picks a target
// inside a resolved nested prefab, sm_local_id_get_or_mint must create a
// Breadcrumb so the reference survives save+reload and binds to the same
// runtime object on the reloaded scene.
//
// This is the core regression: previously sm_local_id_get_or_mint just minted
// an unanchored bimap entry, so on reload the lid was unknown and Ref_Local
// stayed unresolved.
@(test)
test_ref_local_pick_nested_target_roundtrips :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	path := "moonhug/tests/fixtures/_test_ref_local_pick.scene"
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, path)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil, "TestA load failed")
	if loaded == nil do return
	tc_mem.scene = loaded

	// Pick a transform inside a nested prefab — TransformC lives inside TestB
	// (which is itself nested inside TestA's root).
	host_b := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_b, "TransformC")
	testing.expect(t, host_b != {} && transform_c_h != {}, "expected TestB and nested TransformC")
	if host_b == {} || transform_c_h == {} do return

	chosen_handle := engine.Handle(transform_c_h)

	// Simulate the picker: ask the bimap for a lid for this nested-owned
	// handle. Since it isn't in the bimap, this must create a Breadcrumb and
	// return its placeholder lid.
	lid := engine.sm_local_id_get_or_mint(loaded, chosen_handle)
	testing.expect(t, lid != 0, "sm_local_id_get_or_mint should return a non-zero lid for nested-owned target")

	// The newly created entry must point at the real handle in the bimap so
	// in-session reverse-lookup dedupes (calling again with same handle
	// returns the same lid, not a fresh one).
	{
		bimap_lid, ok := loaded.local_ids.backward[chosen_handle]
		testing.expect(t, ok && bimap_lid == lid, "bimap reverse-lookup must return the breadcrumb lid")
		again := engine.sm_local_id_get_or_mint(loaded, chosen_handle)
		testing.expect_value(t, again, lid)
	}

	// Save, then reload from disk. The breadcrumb must persist and resolve
	// back to a handle pointing at "TransformC" inside the reloaded TestB.
	ok := engine.scene_save(loaded, path)
	testing.expect(t, ok, "scene_save failed")
	if !ok do return

	reloaded := engine.scene_load_single_path(path)
	testing.expect(t, reloaded != nil, "reload after save failed")
	if reloaded == nil do return
	tc_mem.scene = reloaded

	// After reload, the bimap entry for `lid` should resolve to a handle whose
	// underlying transform is named "TransformC" inside the reloaded TestB.
	resolved_handle, has_lid := reloaded.local_ids.forward[lid]
	testing.expect(t, has_lid, "reloaded scene must have the breadcrumb lid in local_ids")
	if !has_lid do return

	host_b2 := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	tc_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_b2, "TransformC")
	testing.expect(t, host_b2 != {} && tc_h2 != {}, "expected TestB+TransformC after reload")
	if host_b2 == {} || tc_h2 == {} do return

	testing.expect_value(t, resolved_handle, engine.Handle(tc_h2))
}

@(test)
test_ref_local_pick_local_target_no_breadcrumb :: proc(t: ^testing.T) {
	// Picking a target that's already in the root scene's bimap (a local,
	// non-nested transform) must NOT create a breadcrumb; it just returns the
	// existing lid.
	path := "moonhug/tests/fixtures/_test_ref_local_pick_local.scene"
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, path)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer os.remove(path)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", rootH)
	testing.expect(t, childH != {})
	if childH == {} do return

	bcs_before := len(tc_mem.scene.breadcrumb_data)
	lid := engine.sm_local_id_get_or_mint(tc_mem.scene, engine.Handle(childH))
	testing.expect(t, lid != 0)
	bcs_after := len(tc_mem.scene.breadcrumb_data)

	testing.expect_value(t, bcs_after, bcs_before)

	// And the lid must be the transform's own local_id (already in bimap from
	// transform_new).
	t_child := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	testing.expect_value(t, lid, t_child.local_id)
}
