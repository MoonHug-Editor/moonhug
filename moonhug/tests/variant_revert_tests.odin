package tests

// Reverting an override on a Prefab Variant's ROOT content must restore the
// field VALUE, not just drop the record (docs/PrefabsSpec.md §4.7).
//
// A root variant is the case where the base prefab's root IS the variant's root
// (§6.2), so the overridden object is the scene root itself rather than a child.

import engine "../engine"
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

	// SpriteRootVariant overrides Light.color to blue on the base root.
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
		if c.handle.type_key == .Light do comp_h = c.handle
	}
	testing.expect(t, comp_h != {}, "the variant root should carry a Light")
	if comp_h == {} do return
	raw := engine.world_pool_get(&tc_mem.world, comp_h)
	if raw == nil do return
	lt := cast(^engine.Light)raw

	// The variant's override is in effect: blue, not the base's value.
	overridden := lt.color
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

	lt_after := cast(^engine.Light)engine.world_pool_get(&tc_mem.world, comp_h)
	if lt_after == nil do return
	testing.expectf(t, lt_after.color != overridden,
		"revert must restore the base VALUE, still %v", lt_after.color)
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

