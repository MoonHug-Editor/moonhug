package tests

import "../engine"

import "core:testing"
import "core:strings"
import "core:encoding/uuid"

@(test)
test_breadcrumb_resolve_host_anchors :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	append(&s.nested_scenes, engine.NestedScene{local_id = 13, transform_parent = 12, host_breadcrumb_id = 14})
	append(&s.nested_scenes, engine.NestedScene{local_id = 16, transform_parent = 15, host_breadcrumb_id = 17})
	engine.scene_breadcrumb_put(
		s,
		engine.Breadcrumb{
			local_id       = 14,
			scene_source   = engine.PPtr{local_id = 12, guid = engine.Asset_GUID{}},
			scene_instance = 13,
		},
	)
	engine.scene_breadcrumb_put(
		s,
		engine.Breadcrumb{
			local_id       = 17,
			scene_source   = engine.PPtr{local_id = 15, guid = engine.Asset_GUID{}},
			scene_instance = 16,
		},
	)

	b14, ok14 := engine.breadcrumb_get(s, 14)
	testing.expect(t, ok14)
	if ok14 {
		testing.expect_value(t, b14.scene_source.local_id, engine.Local_ID(12))
		testing.expect_value(t, b14.scene_instance, engine.Local_ID(13))
	}

	b17, ok17 := engine.breadcrumb_get(s, 17)
	testing.expect(t, ok17)
	if ok17 {
		testing.expect_value(t, b17.scene_source.local_id, engine.Local_ID(15))
		testing.expect_value(t, b17.scene_instance, engine.Local_ID(16))
	}

	_, bad0 := engine.breadcrumb_get(s, 0)
	testing.expect(t, !bad0)
	_, bad99 := engine.breadcrumb_get(s, 99)
	testing.expect(t, !bad99)
}

@(test)
test_breadcrumb_create_allocates_idempotent_and_scoped :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	append(&s.nested_scenes, engine.NestedScene{local_id = 200})
	append(&s.nested_scenes, engine.NestedScene{local_id = 201})

	src := engine.PPtr{local_id = 12, guid = engine.Asset_GUID{}}

	ph1, ok1 := engine.breadcrumb_create(s, 200, src)
	testing.expect(t, ok1)
	testing.expect(t, ph1 != 0)
	testing.expect_value(t, len(s.breadcrumb_data), 1)

	ph1b, ok1b := engine.breadcrumb_create(s, 200, src)
	testing.expect(t, ok1b)
	testing.expect_value(t, ph1b, ph1)
	testing.expect_value(t, len(s.breadcrumb_data), 1)

	ph2, ok2 := engine.breadcrumb_create(s, 201, src)
	testing.expect(t, ok2)
	testing.expect(t, ph2 != 0)
	testing.expect_value(t, len(s.breadcrumb_data), 2)
	testing.expect(t, ph2 != ph1)

	_, bad := engine.breadcrumb_create(s, 999, src)
	testing.expect(t, !bad)
}

@(test)
test_resolve_host_and_breadcrumb_when_nested_file_id_matches_native :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil, "TestA load failed (asset DB or path)")
	if loaded == nil do return
	tc_mem.scene = loaded

	s := tc_mem.scene
	w := &tc_mem.world

	host_b := find_transform_named(w, s, "TestB", false)
	host_b2 := find_transform_named(w, s, "TestB2", false)
	nested_c_b := find_nested_named_under_host(w, s, host_b, "TestC")
	nested_c_b2 := find_nested_named_under_host(w, s, host_b2, "TestC")

	testing.expect(t, host_b != {} && host_b2 != {} && nested_c_b != {} && nested_c_b2 != {})
	if host_b == {} || host_b2 == {} || nested_c_b == {} || nested_c_b2 == {} do return

	host_b_t := engine.pool_get(&w.transforms, engine.Handle(host_b))
	host_b2_t := engine.pool_get(&w.transforms, engine.Handle(host_b2))
	nested_c_t := engine.pool_get(&w.transforms, engine.Handle(nested_c_b))
	testing.expect(t, host_b_t != nil && host_b2_t != nil && nested_c_t != nil)
	if host_b_t == nil || host_b2_t == nil || nested_c_t == nil do return

	testing.expect(t, engine.Handle(nested_c_b) != engine.Handle(nested_c_b2))

	ns_b := engine.scene_find_nested_scene_for_host(s, host_b)
	ns_b2 := engine.scene_find_nested_scene_for_host(s, host_b2)
	testing.expect(t, ns_b != nil && ns_b2 != nil)
	if ns_b == nil || ns_b2 == nil do return

	testing.expect(t, engine.nested_scene_hosts_transform(s, ns_b, host_b))
	testing.expect(t, engine.nested_scene_hosts_transform(s, ns_b2, host_b2))
	testing.expect(t, engine.nested_scene_resolve_host_handle(s, ns_b) == host_b)
	testing.expect(t, engine.nested_scene_resolve_host_handle(s, ns_b2) == host_b2)

	bc_b, ok_b := engine.breadcrumb_get(s, ns_b.host_breadcrumb_id)
	testing.expect(t, ok_b)
	if ok_b {
		testing.expect_value(t, bc_b.scene_instance, ns_b.local_id)
		testing.expect_value(t, bc_b.scene_source.local_id, host_b_t.local_id)
	}
	bc_b2, ok_b2 := engine.breadcrumb_get(s, ns_b2.host_breadcrumb_id)
	testing.expect(t, ok_b2)
	if ok_b2 {
		testing.expect_value(t, bc_b2.scene_instance, ns_b2.local_id)
		testing.expect_value(t, bc_b2.scene_source.local_id, host_b2_t.local_id)
	}

	testing.expect(t, engine.transform_find_nested_host(nested_c_b) == host_b)
	testing.expect(t, engine.transform_find_nested_host(nested_c_b2) == host_b2)

	root_h := engine.Transform_Handle(s.root.handle)
	transform_a := find_transform_named(w, s, "TransformA", false)
	testing.expect(t, engine.scene_find_nested_scene_for_host(s, root_h) == nil)
	testing.expect(t, transform_a != {} && engine.scene_find_nested_scene_for_host(s, transform_a) == nil)

	testing.expect(t, hierarchy_shows_nested_scene_suffix(w, host_b))
	testing.expect(t, hierarchy_shows_nested_scene_suffix(w, host_b2))
	testing.expect(t, hierarchy_shows_nested_scene_suffix(w, nested_c_b))
	testing.expect(t, hierarchy_shows_nested_scene_suffix(w, nested_c_b2))
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(w, root_h))
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(w, transform_a))

	_, ok_peg := engine.scene_find_outer_transform_local_id(s, 14)
	testing.expect(t, !ok_peg)

	root_t := engine.pool_get(&w.transforms, engine.Handle(root_h))
	if root_t != nil {
		for cref in root_t.children {
			ch, ok := engine.scene_ref_resolve_transform(s, cref, root_h)
			testing.expect(t, ok)
			if !ok do continue
			ch_t := engine.pool_get(&w.transforms, engine.Handle(ch))
			testing.expect(t, ch_t != nil && ch_t.parent.handle == engine.Handle(root_h))
		}
	}

	nested_c_b_t := engine.pool_get(&w.transforms, engine.Handle(nested_c_b))
	if nested_c_b_t != nil {
		// Locate TransformC among TestC's children (TestC also nests TestD now,
		// so the child list contains both TransformC and TestD's host).
		found_transform_c := false
		for cref in nested_c_b_t.children {
			ch, ok := engine.scene_ref_resolve_transform(s, cref, nested_c_b)
			testing.expect(t, ok)
			if !ok do continue
			deep := engine.pool_get(&w.transforms, engine.Handle(ch))
			testing.expect(t, deep != nil && deep.parent.handle == engine.Handle(nested_c_b))
			if deep != nil && strings.compare(deep.name, "TransformC") == 0 {
				found_transform_c = true
			}
		}
		testing.expect(t, found_transform_c, "expected TransformC among TestC's children")
	}
}

// Per NestedPrefabs.md: breadcrumbs exist specifically for cross-asset references
// (different referrer source_prefab vs reference source_prefab). The other tests
// only exercise the empty-guid path; this one verifies the cross-boundary case.
@(test)
test_breadcrumb_cross_asset_roundtrip :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	guid_id, guid_err := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	testing.expect(t, guid_err == nil)
	if guid_err != nil do return
	asset := engine.Asset_GUID(guid_id)

	src := engine.PPtr{local_id = 7, guid = asset}
	bc_in := engine.Breadcrumb{local_id = 42, scene_source = src, scene_instance = 11}
	testing.expect(t, engine.scene_breadcrumb_put(s, bc_in))

	got, ok := engine.breadcrumb_get(s, 42)
	testing.expect(t, ok)
	testing.expect_value(t, got.scene_instance, engine.Local_ID(11))
	testing.expect_value(t, got.scene_source.local_id, engine.Local_ID(7))
	testing.expect(t, got.scene_source.guid == asset)
	testing.expect(t, !engine.pptr_guid_is_empty(got.scene_source.guid))
}

// breadcrumb_create must dedup on (scene_instance, src) regardless of whether
// src.guid is empty. Existing test only covers empty-guid; this covers populated.
@(test)
test_breadcrumb_create_dedup_with_non_empty_guid :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	append(&s.nested_scenes, engine.NestedScene{local_id = 200})

	guid_a, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	guid_b, _ := uuid.read("11111111-2222-3333-4444-555555555555")
	src_a := engine.PPtr{local_id = 7, guid = engine.Asset_GUID(guid_a)}
	src_b := engine.PPtr{local_id = 7, guid = engine.Asset_GUID(guid_b)}

	ph1, ok1 := engine.breadcrumb_create(s, 200, src_a)
	testing.expect(t, ok1)
	ph1_again, ok1b := engine.breadcrumb_create(s, 200, src_a)
	testing.expect(t, ok1b)
	testing.expect_value(t, ph1_again, ph1)
	testing.expect_value(t, len(s.breadcrumb_data), 1)

	// Same scene_instance + same local_id but DIFFERENT guid -> distinct breadcrumb.
	ph2, ok2 := engine.breadcrumb_create(s, 200, src_b)
	testing.expect(t, ok2)
	testing.expect(t, ph2 != ph1)
	testing.expect_value(t, len(s.breadcrumb_data), 2)
}

// breadcrumb_materialize_target has two branches:
//   - empty guid: passthrough (target returned as-is, no breadcrumb stored)
//   - populated guid: allocate breadcrumb and return PPtr{peg, empty_guid}
@(test)
test_breadcrumb_materialize_target_branches :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	append(&s.nested_scenes, engine.NestedScene{local_id = 200})

	in_local := engine.PPtr{local_id = 7, guid = engine.Asset_GUID{}}
	out_local, ok_local := engine.breadcrumb_materialize_target(s, 200, in_local)
	testing.expect(t, ok_local)
	testing.expect(t, engine.pptr_equals(out_local, in_local))
	testing.expect_value(t, len(s.breadcrumb_data), 0)

	guid_id, _ := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	in_cross := engine.PPtr{local_id = 7, guid = engine.Asset_GUID(guid_id)}
	out_cross, ok_cross := engine.breadcrumb_materialize_target(s, 200, in_cross)
	testing.expect(t, ok_cross)
	testing.expect(t, engine.pptr_guid_is_empty(out_cross.guid))
	testing.expect_value(t, len(s.breadcrumb_data), 1)

	bc, bc_ok := engine.breadcrumb_get(s, out_cross.local_id)
	testing.expect(t, bc_ok)
	testing.expect_value(t, bc.scene_instance, engine.Local_ID(200))
	testing.expect_value(t, bc.scene_source.local_id, engine.Local_ID(7))
	testing.expect(t, bc.scene_source.guid == engine.Asset_GUID(guid_id))

	// Idempotency: a second materialize for the same target reuses the same breadcrumb.
	out_cross2, ok_cross2 := engine.breadcrumb_materialize_target(s, 200, in_cross)
	testing.expect(t, ok_cross2)
	testing.expect_value(t, out_cross2.local_id, out_cross.local_id)
	testing.expect_value(t, len(s.breadcrumb_data), 1)
}

// scene_file_remap_merge_metadata (nested_scene.odin:27) must rewire
// host_breadcrumb_id when the merged file's breadcrumb id collides with an
// existing local_id in the live scene.
@(test)
test_remap_merge_rewires_host_breadcrumb_id_on_collision :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	// Reserve id 30 in the live scene's local_ids forward map so any incoming
	// breadcrumb that wants id 30 must be remapped.
	engine.bimap_insert(&s.local_ids, engine.Local_ID(30), engine.Handle{index = 999, generation = 1, type_key = .Transform})

	sf := engine.SceneFile{}
	defer engine.scene_file_destroy(&sf)
	append(&sf.nested_scenes, engine.NestedScene{
		local_id           = 21,
		transform_parent   = 5,
		host_breadcrumb_id = 30, // points to the breadcrumb whose id will be remapped
	})
	append(&sf.breadcrumbs, engine.Breadcrumb{
		local_id       = 30,
		scene_source   = engine.PPtr{local_id = 5, guid = engine.Asset_GUID{}},
		scene_instance = 21,
	})

	engine.scene_file_remap_merge_metadata(&sf, s)

	// The colliding breadcrumb id was reminted — the nested scene's
	// host_breadcrumb_id must follow it or the host pointer dangles.
	testing.expect(t, sf.breadcrumbs[0].local_id != 30)
	testing.expect_value(t, sf.nested_scenes[0].host_breadcrumb_id, sf.breadcrumbs[0].local_id)
	testing.expect_value(t, sf.breadcrumbs[0].scene_instance, sf.nested_scenes[0].local_id)
}
