package prefabs_example_tests

// Save and revert invariants over this package's committed prefab chain
// (../assets): an unchanged save writes no edits, a variant's root override
// reverts through undo, the asset db links a variant to its base.

import "core:testing"
import "moonhug:engine"
import "moonhug:editor/undo"
import common "moonhug:tests/common"

// An UNCHANGED load->save must not invent structural component edits. Lid
// matching alone can't classify a component: one owned by a DEEPER nesting
// level un-projects with that level's table, not the level being captured, so
// it stays composed and reads as an unmatched (added) row. The live
// `nested_owned` flag is the authority instead. This is the shape of the bug
// that shipped a phantom added_components entry into blobs.scene.
@(test)
test_unchanged_save_invents_no_component_edits :: proc(t: ^testing.T) {
	ASSETS :: "moonhug/packages/prefabs_example/assets"
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "moonhug/tests/fixtures/_test_no_phantom_comps.scene")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// host.scene nests a chain deep enough that inner levels own components
	// the capturing level cannot un-project.
	for path in ([]string{ASSETS + "/host.scene", ASSETS + "/blobs.scene", ASSETS + "/blobs_Variant.scene"}) {
		loaded := engine.scene_load_single_path(path)
		testing.expectf(t, loaded != nil, "load %s", path)
		if loaded == nil do continue
		tc_mem.scene = loaded
		engine.sm_scene_set_active(loaded)

		data, ok := engine.scene_serialize(loaded)
		testing.expectf(t, ok, "serialize %s", path)
		if ok do delete(data)

		for &ns in loaded.nested_scenes {
			testing.expectf(t, len(ns.added_components) == 0,
				"%s: unchanged save invented %d added_components", path, len(ns.added_components))
			testing.expectf(t, len(ns.removed_components) == 0,
				"%s: unchanged save invented %d removed_components", path, len(ns.removed_components))
		}
		engine.sm_scene_destroy_or_unload(loaded)
		engine.sm_scene_set_active(nil)
		tc_mem.scene = nil
	}
}

// --- Structural OBJECT edits on a prefab instance ----------------------------

// A transform added under prefab content is recorded as an added_object and
// grafted back at resolve, so it survives a full save/reload — not just the
// save. HostDup nests SpriteDup (SpriteA/SpriteB) under a regular host.

// An unchanged load->save must not invent object edits. The live walk skips the
// base root and inner-NS content, so "absent from the walk" does NOT mean the
// user removed something — inferring removals that way invented them.
@(test)
test_unchanged_save_invents_no_object_edits :: proc(t: ^testing.T) {
	ASSETS :: "moonhug/packages/prefabs_example/assets"
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "moonhug/tests/fixtures/_test_no_phantom_objs.scene")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	for path in ([]string{ASSETS + "/host.scene", ASSETS + "/blobs.scene", ASSETS + "/blobs_Variant.scene"}) {
		loaded := engine.scene_load_single_path(path)
		testing.expectf(t, loaded != nil, "load %s", path)
		if loaded == nil do continue
		tc_mem.scene = loaded
		engine.sm_scene_set_active(loaded)

		data, ok := engine.scene_serialize(loaded)
		if ok do delete(data)

		for &ns in loaded.nested_scenes {
			testing.expectf(t, len(ns.added_objects) == 0,
				"%s: unchanged save invented %d added_objects", path, len(ns.added_objects))
			testing.expectf(t, len(ns.removed_objects) == 0,
				"%s: unchanged save invented %d removed_objects", path, len(ns.removed_objects))
		}
		engine.sm_scene_destroy_or_unload(loaded)
		engine.sm_scene_set_active(nil)
		tc_mem.scene = nil
	}
}

// Deleting prefab content records a removed_object, so the next resolve — which
// rebuilds the instance from its prefab — does not bring it back.

// Undo of a revert on a variant ROOT must restore the override record AND the
// value (docs/PrefabsSpec.md §4.7 + §8.2). The property menu's Revert pairs a
// Value_Command with record bookkeeping; both halves have to survive undo.
@(test)
test_variant_root_revert_undo_restores_override :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/packages/prefabs_example/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "moonhug/tests/fixtures/_test_cvariant_undo.scene")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	u := new(undo.Undo_Stack)
	undo.init(u)
	undo.install(u)
	defer { undo.destroy(u); free(u) }

	loaded := engine.scene_load_single_path(
		"moonhug/packages/prefabs_example/assets/c_Variant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	ns := engine.scene_find_nested_scene_for_host(loaded, root_tH)
	testing.expect(t, ns != nil, "the root variant's NS should resolve")
	if ns == nil do return

	entries := engine.nested_scene_list_overrides(loaded, ns)
	before := len(entries)
	testing.expectf(t, before >= 1, "c_Variant ships with overrides, got %d", before)
	if before == 0 do return

	// Revert the first field override the way the property menu does.
	victim := engine.Override_Entry{}
	found := false
	for e in entries {
		if e.kind == .Modified_Property { victim = e; found = true; break }
	}
	testing.expect(t, found, "expected a field override to revert")
	if !found do return

	fp, ftid, owner, ok := engine.nested_scene_find_revert_target(
		loaded, ns, victim.target, victim.property_path)
	testing.expect(t, ok, "the live field must resolve for revert")
	snap := undo.override_removal_snapshot(ns, victim.target, victim.property_path)
	if ok do undo.push_pooled_owner(owner)
	scope := undo.edit_inspector_field_begin(fp, ftid, "Revert Override") if ok else undo.Edit_Scope{}
	engine.nested_scene_revert_override(loaded, ns, victim.target, victim.property_path, fp)
	if ok {
		undo.edit_end(&scope)
		undo.pop_owner()
	}
	undo.record_override_removed(loaded, root_tH, victim.target.local_id,
		victim.property_path, snap)

	testing.expect(t, !engine.nested_scene_has_override(ns, victim.target, victim.property_path),
		"revert should drop the record")

	// UNDO: the override must come back.
	testing.expect(t, undo.can_undo(u), "the revert must produce an undo step")
	undo.apply_undo(u)

	ns = engine.scene_find_nested_scene_for_host(loaded, root_tH)
	if ns == nil do return
	testing.expect(t, engine.nested_scene_has_override(ns, victim.target, victim.property_path),
		"undo of a revert MUST restore the override record")
}

// The inspector header shows a Base ref for a Prefab Variant, so the AssetDB
// has to record which Base Prefab a variant inherits from.

@(test)
test_asset_db_records_variant_base_prefab :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "moonhug/tests/fixtures/_test_base_guid.scene")
	engine.asset_db_init("moonhug/packages/prefabs_example/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// c_Variant inherits from c.scene.
	var_guid, vok := engine.asset_db_get_guid("moonhug/packages/prefabs_example/assets/c_Variant.scene")
	testing.expect(t, vok, "c_Variant should be in the AssetDB")
	base_guid, bok := engine.asset_db_get_guid("moonhug/packages/prefabs_example/assets/c.scene")
	testing.expect(t, bok, "c.scene should be in the AssetDB")
	if !vok || !bok do return

	info, ok := engine.asset_db_get_root_info(engine.Asset_GUID(var_guid))
	testing.expect(t, ok, "c_Variant should have root info")
	if !ok do return
	testing.expect(t, info.is_variant, "c_Variant must be flagged a variant")
	testing.expectf(t, info.base_prefab == engine.Asset_GUID(base_guid),
		"base_prefab must name c.scene, got %v", info.base_prefab)

	// A plain prefab has no base.
	if pinfo, pok := engine.asset_db_get_root_info(engine.Asset_GUID(base_guid)); pok {
		testing.expect(t, !pinfo.is_variant, "c.scene is not a variant")
		testing.expect(t, pinfo.base_prefab == engine.Asset_GUID{},
			"a plain prefab must carry no base")
	}
}
