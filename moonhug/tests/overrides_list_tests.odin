package tests

// The Overrides dropdown's model: nested_scene_list_overrides flattens all four
// record kinds into one displayable list, and nested_override_entry_revert
// removes whichever kind a row names.

import engine "../engine"
import "../editor/undo"
import "core:strings"
import "core:testing"

@(test)
test_overrides_list_covers_every_record_kind :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_ov_list.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_a := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	testing.expect(t, sprite_a != {}, "nested SpriteA should resolve")
	if sprite_a == {} do return
	host_tH := engine.transform_immediate_nested_host(sprite_a)
	testing.expect(t, host_tH != {})
	if host_tH == {} do return

	ht := engine.pool_get(&tc_mem.world.transforms, engine.Handle(host_tH))
	if ht == nil do return
	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	testing.expect(t, ns != nil, "host should own a native NS")
	if ns == nil do return

	// HostDup.scene ships with a name override on the host, so the list is not
	// empty to begin with — measure against that baseline, not against zero.
	baseline := len(engine.nested_scene_list_overrides(loaded, ns))

	// 1. A field override.
	at := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at == nil do return
	at.name = "Renamed"
	_, rec_ok := engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "name", &at.name, typeid_of(string),
	)
	testing.expect(t, rec_ok, "recording a field override should succeed")

	// 2. An added object.
	added := engine.transform_new("ListedChild", sprite_a)
	testing.expect(t, added != {})

	// 3. A removed object.
	victim := find_transform_named(&tc_mem.world, loaded, "SpriteB", true)
	testing.expect(t, victim != {}, "nested SpriteB should resolve")
	if victim == {} do return
	vt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(victim))
	if vt == nil do return
	victim_lid := vt.local_id
	engine.transform_destroy(victim)
	_, rm_ok := engine.nested_scene_record_object_removed(loaded, host_tH, victim_lid)
	testing.expect(t, rm_ok, "deleting prefab content should record a removal")

	// The added object is only captured on save, so round-trip to get all
	// four kinds onto the record set the way the editor would.
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))
	ns = engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return

	entries := engine.nested_scene_list_overrides(loaded, ns)
	testing.expectf(t, len(entries) >= baseline + 3,
		"expected %d baseline + 3 new rows, got %d", baseline, len(entries))

	kinds: map[engine.Override_Entry_Kind]int
	defer delete(kinds)
	for e in entries {
		kinds[e.kind] += 1
		testing.expectf(t, e.object_label != "", "every row needs an object label (kind %v)", e.kind)
		testing.expectf(t, e.detail != "", "every row needs a detail (kind %v)", e.kind)
	}
	testing.expect(t, kinds[.Modified_Property] > 0, "the field override must be listed")
	testing.expect(t, kinds[.Removed_Object] > 0, "the object removal must be listed")
	testing.expect(t, kinds[.Added_Object] > 0, "the object addition must be listed")
}

@(test)
test_overrides_revert_removes_only_the_named_record :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_ov_revert.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_a := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	if sprite_a == {} do return
	host_tH := engine.transform_immediate_nested_host(sprite_a)
	if host_tH == {} do return
	ht := engine.pool_get(&tc_mem.world.transforms, engine.Handle(host_tH))
	if ht == nil do return
	at := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at == nil do return

	// Two field overrides on the same object, so reverting one must leave the
	// other — the dropdown reverts per row, not per object.
	at.name = "Renamed"
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "name", &at.name, typeid_of(string),
	)
	at.is_active = false
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "is_active", &at.is_active, typeid_of(bool),
	)

	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return

	// The host carries its own name override from the fixture, so rows must be
	// matched on the TARGET too — SpriteA's source lid, not just the path.
	at_src_lid := at.local_id
	if src, has := ns.source_of_inst[at.local_id]; has do at_src_lid = src

	entries := engine.nested_scene_list_overrides(loaded, ns)
	before := len(entries)
	testing.expectf(t, before >= 2, "expected at least the 2 new rows, got %d", before)
	if before < 2 do return

	// Revert the "name" row specifically.
	victim_idx := -1
	for e, i in entries {
		if strings.compare(e.property_path, "name") == 0 && e.target.local_id == at_src_lid {
			victim_idx = i
		}
	}
	testing.expect(t, victim_idx >= 0, "SpriteA's name override should be listed")
	if victim_idx < 0 do return
	testing.expect(t, engine.nested_override_entry_revert(loaded, ns, entries[victim_idx]),
		"reverting a listed row should report success")

	after := engine.nested_scene_list_overrides(loaded, ns)
	testing.expectf(t, len(after) == before - 1,
		"exactly one row should go, %d -> %d", before, len(after))
	survived := false
	for e in after {
		if strings.compare(e.property_path, "is_active") == 0 do survived = true
	}
	testing.expect(t, survived, "the row that was NOT selected must survive")

	// Reverting the same row twice is a no-op, not a double free — the list the
	// UI holds can outlive the record when another revert lands first.
	testing.expect(t, !engine.nested_override_entry_revert(loaded, ns, entries[victim_idx]),
		"reverting an already-gone record should report false")
}

// Reverting from the dropdown must be undoable. It has no paired live-world
// command to lean on (unlike the property menu's Revert, which rides its
// Value_Command), so the record is rebuilt from a snapshot taken before the
// revert — including the heap payload of the structural kinds.
@(test)
test_overrides_dropdown_revert_is_undoable :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_ov_undo.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	u := new(undo.Undo_Stack)
	undo.init(u)
	undo.install(u)
	defer { undo.destroy(u); free(u) }

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_a := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	if sprite_a == {} do return
	host_tH := engine.transform_immediate_nested_host(sprite_a)
	if host_tH == {} do return
	ht := engine.pool_get(&tc_mem.world.transforms, engine.Handle(host_tH))
	if ht == nil do return
	at := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at == nil do return

	// A field override AND a structural one, so the group mixes kinds the way
	// "Revert Selected" over several rows does.
	at.name = "Renamed"
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "name", &at.name, typeid_of(string),
	)

	// A removed object: a structural record whose restore needs the snapshot.
	victim := find_transform_named(&tc_mem.world, loaded, "SpriteB", true)
	if victim == {} do return
	vt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(victim))
	if vt == nil do return
	victim_lid := vt.local_id
	engine.transform_destroy(victim)
	engine.nested_scene_record_object_removed(loaded, host_tH, victim_lid)

	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return
	before := len(engine.nested_scene_list_overrides(loaded, ns))
	testing.expect(t, before > 0, "the removal should be listed")

	// Revert every row the way "Revert All" does. Field rows go through the
	// SAME path the property menu's Revert uses (a Value_Command wrapping the
	// live field), which is what makes redo restore the value too.
	entries := engine.nested_scene_list_overrides(loaded, ns)
	undo.begin_group_command(u)
	for i := len(entries) - 1; i >= 0; i -= 1 {
		e := entries[i]
		if e.kind == .Modified_Property {
			fp, ftid, owner, found := engine.nested_scene_find_revert_target(loaded, ns, e.target, e.property_path)
			snap := undo.override_removal_snapshot(ns, e.target, e.property_path)
			// The Value_Command is keyed by the object that CONTAINS the field,
			// which is the row's target, not the inspected object.
			if found do undo.push_pooled_owner(owner)
			scope := undo.edit_inspector_field_begin(fp, ftid, "Revert Override") if found else undo.Edit_Scope{}
			engine.nested_scene_revert_override(loaded, ns, e.target, e.property_path, fp)
			if found {
				undo.edit_end(&scope)
				undo.pop_owner()
			}
			undo.record_override_removed(loaded, host_tH, e.target.local_id, e.property_path, snap)
			continue
		}
		snap := engine.nested_override_snapshot(ns, e)
		if engine.nested_override_entry_revert(loaded, ns, e) {
			undo.record_dropdown_revert(loaded, host_tH, e.kind, e.target, e.property_path, nil, snap)
		} else {
			engine.nested_override_snapshot_destroy(&snap)
		}
	}
	undo.end_group_command(u, "Revert Override")

	ns = engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return
	testing.expect(t, len(engine.nested_scene_list_overrides(loaded, ns)) == 0,
		"Revert All should clear every row")

	testing.expect(t, undo.can_undo(u), "the revert must produce an undo step")
	undo.apply_undo(u)

	ns = engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return
	after := len(engine.nested_scene_list_overrides(loaded, ns))
	testing.expectf(t, after == before,
		"undo must restore every reverted record: %d -> 0 -> %d", before, after)

	// The VALUE must come back with the record, not just the bookkeeping —
	// otherwise the field reads as overridden while holding its baseline.
	at2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at2 != nil {
		testing.expectf(t, strings.compare(at2.name, "Renamed") == 0,
			"undo must restore the overridden VALUE, got %q", at2.name)
	}

	// REDO must drop them again.
	testing.expect(t, undo.can_redo(u), "the revert must be redoable")
	undo.apply_redo(u)
	ns = engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return
	redone := len(engine.nested_scene_list_overrides(loaded, ns))
	testing.expectf(t, redone == 0,
		"redo must re-apply the revert: %d rows still present", redone)
	at3 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at3 != nil {
		testing.expectf(t, strings.compare(at3.name, "SpriteA") == 0,
			"redo must re-apply the reverted VALUE, got %q", at3.name)
	}
}

// The comparison view's left pane: the object's values as the PREFAB defines
// them. Must materialize a real typed instance for BOTH a transform and a
// component, and must report the PREFAB's value even when the live instance has
// been overridden — that difference is the whole point of the two panes.
@(test)
test_override_baseline_materializes_prefab_values :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_ov_baseline.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_a := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	if sprite_a == {} do return
	host_tH := engine.transform_immediate_nested_host(sprite_a)
	if host_tH == {} do return
	ht := engine.pool_get(&tc_mem.world.transforms, engine.Handle(host_tH))
	if ht == nil do return
	at := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at == nil do return
	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return

	src_lid := at.local_id
	if s2, has := ns.source_of_inst[at.local_id]; has do src_lid = s2
	target := engine.PPtr{guid = ns.source_prefab, local_id = src_lid}

	// TRANSFORM baseline: overriding the live name must NOT move the baseline.
	at.name = "Renamed"
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "name", &at.name, typeid_of(string),
	)

	base := engine.nested_override_baseline(loaded, ns, target)
	testing.expect(t, base.ok, "the transform baseline should materialize")
	if base.ok {
		bt := cast(^engine.Transform)base.ptr
		testing.expectf(t, strings.compare(bt.name, "SpriteA") == 0,
			"baseline must hold the PREFAB name, got %q", bt.name)
		testing.expect(t, base.tid == typeid_of(engine.Transform), "baseline names its type")
	}

	// COMPONENT baseline: SpriteA carries a SpriteRenderer in SpriteDup.scene.
	comp_key := engine.TypeKey.SpriteRenderer
	comp_h := engine.Handle{}
	for c in at.components {
		if c.handle.type_key == comp_key do comp_h = c.handle
	}
	testing.expect(t, comp_h != {}, "SpriteA should carry a SpriteRenderer")
	if comp_h == {} do return

	raw := engine.world_pool_get(&tc_mem.world, comp_h)
	testing.expect(t, raw != nil)
	if raw == nil do return
	comp_lid := (cast(^engine.CompData)raw).local_id
	comp_src := comp_lid
	if s2, has := ns.source_of_inst[comp_lid]; has do comp_src = s2

	cbase := engine.nested_override_baseline(
		loaded, ns, engine.PPtr{guid = ns.source_prefab, local_id = comp_src}, comp_key,
	)
	testing.expect(t, cbase.ok, "the component baseline should materialize")
	if cbase.ok {
		testing.expect(t, cbase.ptr != nil, "a component baseline needs backing memory")
		testing.expectf(t, cbase.tid == engine.get_typeid_by_type_key(comp_key),
			"the baseline must be typed as its component, got %v", cbase.tid)
	}

	// The live handle both panes key off must name the component, not its owner.
	live := engine.nested_override_live_handle(
		loaded, ns, engine.PPtr{guid = ns.source_prefab, local_id = comp_src},
	)
	testing.expectf(t, live.type_key == comp_key,
		"a component target must resolve to the component, got %v", live.type_key)
}

// The list shows one element per COMPONENT (or the transform), never per field:
// several changed transform fields read as a single "Transform" element, the way
// Unity groups overrides by component.
@(test)
test_override_tree_groups_rows_by_component :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_ov_group.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_a := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	if sprite_a == {} do return
	host_tH := engine.transform_immediate_nested_host(sprite_a)
	if host_tH == {} do return
	ht := engine.pool_get(&tc_mem.world.transforms, engine.Handle(host_tH))
	if ht == nil do return
	at := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_a))
	if at == nil do return

	// THREE separate transform-field overrides on one object.
	at.name = "Renamed"
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "name", &at.name, typeid_of(string),
	)
	at.position = {1, 2, 3}
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "position", &at.position, typeid_of([3]f32),
	)
	at.scale = {2, 2, 2}
	engine.nested_scene_record_override_for_host(
		loaded, host_tH, at.local_id, "scale", &at.scale, typeid_of([3]f32),
	)

	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil do return
	entries := engine.nested_scene_list_overrides(loaded, ns)
	nodes := engine.nested_scene_override_tree(loaded, ns, host_tH, entries)

	// Transform fields belong to the OBJECT element, not a "Transform" child —
	// the object row already represents the transform.
	found := false
	for node in nodes {
		if node.tH != sprite_a do continue
		found = true
		testing.expectf(t, len(node.own_rows) == 3,
			"all 3 transform fields attach to the object element, got %d", len(node.own_rows))
		for g in node.groups {
			testing.expectf(t, strings.compare(g.label, "Transform") != 0,
				"there must be no duplicate \"Transform\" child element")
			testing.expectf(t, g.kind != .Modified_Property || g.type_key != engine.INVALID_TYPE_KEY,
				"a field group must name a real component, got %v", g.type_key)
		}
	}
	testing.expect(t, found, "SpriteA should appear in the tree")
}
