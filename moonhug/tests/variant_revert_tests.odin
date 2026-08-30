package tests

// Reverting an override on a Prefab Variant's ROOT content must restore the
// field VALUE, not just drop the record (docs/PrefabsSpec.md §4.7).
//
// A root variant is the case where the base prefab's root IS the variant's root
// (§6.2), so the overridden object is the scene root itself rather than a child.

import engine "../engine"
import sprites "moonhug:packages/sprites"
import "../editor/undo"
import "core:strings"
import "core:testing"

@(test)
test_variant_root_revert_restores_value :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_revert_value.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// SpriteRootVariant overrides SpriteRenderer.color to blue on the base root.
	loaded := engine.scene_load_single_path(
		"moonhug/tests/fixtures/nested_scenes/SpriteRootVariant.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(root_tH))
	testing.expect(t, rt != nil, "the variant root should resolve")
	if rt == nil do return

	// The overridden component lives on the root itself.
	comp_h := engine.Handle{}
	for c in rt.components {
		if c.handle.type_key == .SpriteRenderer do comp_h = c.handle
	}
	testing.expect(t, comp_h != {}, "the variant root should carry a SpriteRenderer")
	if comp_h == {} do return
	raw := engine.world_pool_get(&tc_mem.world, comp_h)
	if raw == nil do return
	sr := cast(^sprites.SpriteRenderer)raw

	// The variant's override is in effect: blue, not the base's value.
	overridden := sr.color
	testing.expectf(t, overridden == [4]f32{0, 0, 1, 1},
		"the variant override should be live, got %v", overridden)

	ns := engine.scene_find_nested_scene_for_host(loaded, root_tH)
	testing.expect(t, ns != nil, "the root variant's NS should resolve")
	if ns == nil do return

	comp_lid := (cast(^engine.CompData)raw).local_id
	src_lid := comp_lid
	if s2, has := ns.source_of_inst[comp_lid]; has do src_lid = s2
	target := engine.PPtr{guid = ns.source_prefab, local_id = src_lid}

	testing.expect(t, engine.nested_scene_has_override(ns, target, "color"),
		"color should be recorded as an override on the variant root")

	// REVERT: the record goes away AND the value returns to the base's.
	engine.nested_scene_revert_override(loaded, ns, target, "color")

	testing.expect(t, !engine.nested_scene_has_override(ns, target, "color"),
		"revert must drop the override record")

	sr_after := cast(^sprites.SpriteRenderer)engine.world_pool_get(&tc_mem.world, comp_h)
	if sr_after == nil do return
	testing.expectf(t, sr_after.color != overridden,
		"revert must restore the base VALUE, still %v", sr_after.color)
}

// The Overrides dropdown must resolve a variant root's overrides too — the same
// lid lookup backs the list, the comparison panes and revert, so a root variant
// that could not be reverted also could not be listed with a real object name.
@(test)
test_variant_root_overrides_are_listable :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_variant_list.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path(
		"moonhug/tests/fixtures/nested_scenes/SpriteRootVariant.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	ns := engine.scene_find_nested_scene_for_host(loaded, root_tH)
	testing.expect(t, ns != nil)
	if ns == nil do return

	entries := engine.nested_scene_list_overrides(loaded, ns)
	testing.expectf(t, len(entries) >= 1, "the variant's color override should list, got %d", len(entries))

	for e in entries {
		// A resolved row names its object; an unresolved one falls back to
		// "lid N", which is what the pre-fix lookup produced.
		testing.expectf(t, !strings.has_prefix(e.object_label, "lid "),
			"row should resolve to a live object, got %q", e.object_label)
		live := engine.nested_override_live_handle(loaded, ns, e.target)
		testing.expectf(t, live != {}, "row %q must resolve to a live handle", e.detail)
	}
}

// Undo of a revert on a variant ROOT must restore the override record AND the
// value (docs/PrefabsSpec.md §4.7 + §8.2). The property menu's Revert pairs a
// Value_Command with record bookkeeping; both halves have to survive undo.
@(test)
test_variant_root_revert_undo_restores_override :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/packages/prefabs_example/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_cvariant_undo.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

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
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_base_guid.scene")
	engine.asset_db_init("moonhug/packages/prefabs_example/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

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
