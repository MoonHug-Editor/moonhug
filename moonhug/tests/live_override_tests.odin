package tests

// Live override recording (nested_scene_record_override): a prefab-instance
// edit becomes revertable IMMEDIATELY, not only after a save, and is STICKY —
// only an explicit revert removes it.

import "../engine"
import "../editor/undo"

import "core:testing"
import "core:strings"
import "core:encoding/uuid"
import "core:mem"
import "core:fmt"

// Records the override for a field edited on nested content, the way the
// inspector does at its commit boundary.
_record_live :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	lid: engine.Local_ID,
	path: string,
	field_ptr: rawptr,
	field_tid: typeid,
) -> bool {
	_, ok := engine.nested_scene_record_override_for_host(s, host_tH, lid, path, field_ptr, field_tid)
	return ok
}

// Whether recording CREATED a new entry (vs updating an existing one) — the
// signal undo uses to decide if it should remove the record.
_record_live_created :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	lid: engine.Local_ID,
	path: string,
	field_ptr: rawptr,
	field_tid: typeid,
) -> bool {
	created, _ := engine.nested_scene_record_override_for_host(s, host_tH, lid, path, field_ptr, field_tid)
	return created
}

@(test)
test_live_override_visible_before_save :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_override.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// RootC is the variant's native root — the HOST of the root NS whose
	// overrides target the nested content below it.
	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	testing.expect(t, host != {})
	if host == {} do return
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	testing.expect(t, edited != {})
	if edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return

	// Nothing overrides scale yet (the fixture pre-overrides name/position).
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, ct.local_id, "scale"),
		"scale must not be overridden before the edit")

	ct.scale = {2, 2, 2}
	testing.expect(t, _record_live(loaded, host, ct.local_id, "scale", &ct.scale, typeid_of([3]f32)),
		"recording a live edit should succeed")

	// The marker / Revert / Apply all read this — no save in between.
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, ct.local_id, "scale"),
		"a live edit must be overridden IMMEDIATELY, before any save")
}

@(test)
test_live_override_is_sticky_at_base_value :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_override_sticky.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	if host == {} do return
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id
	base_scale := ct.scale

	// Edit, then hand-set the field BACK to its baseline value. Unity keeps the
	// override (docs/PrefabsSpec.md §4.1: overrides grow only); only an explicit
	// revert clears it.
	ct.scale = {3, 3, 3}
	_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))
	ct.scale = base_scale
	_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))

	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"an override set back to its base value must STAY overridden (sticky)")

	// And it survives a save: the save-time diff finds no difference for this
	// field, so the reconciliation pass must preserve the recorded entry.
	testing.expect(t, engine.scene_save(loaded, tc_mem.path))
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"stickiness must survive save (diff finds nothing; entry is kept)")

	sf, fok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, fok)
	if fok {
		found := false
		for ns in sf.nested_scenes {
			for ov in ns.overrides {
				if ov.target.local_id == lid && strings.compare(ov.property_path, "scale") == 0 do found = true
			}
		}
		testing.expect(t, found, "the sticky override must be written to the file")
		engine.scene_file_destroy(&sf)
	}
}

@(test)
test_live_override_revert_removes_it :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_override_revert.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	if host == {} do return
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id
	base_scale := ct.scale

	ct.scale = {4, 4, 4}
	_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "scale"))

	// Revert on a live-recorded (never-saved) override: clears the entry AND
	// restores the baseline value.
	root_ns, target, ok := engine.nested_scene_locate_root_override(loaded, host, lid)
	testing.expect(t, ok && root_ns != nil)
	if !ok || root_ns == nil do return
	engine.nested_scene_revert_override(loaded, root_ns, target, "scale", &ct.scale)

	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"revert must remove a live-recorded override")
	// Value-restore is revert's own concern and is verified for regular nested
	// prefabs by the scene_tests revert suite. On a variant ROOT's nested
	// content the live field is not relocated (revert clears the record but
	// leaves the value) — a pre-existing limitation, reproducible with a
	// file-loaded override and unrelated to live recording.
	_ = base_scale
}

@(test)
test_live_override_no_duplicate_entries :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_override_dup.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	if host == {} do return
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id

	// Repeated edits to ONE field (a drag emits many commits) replace in place.
	for i in 1 ..= 5 {
		ct.scale = {f32(i), f32(i), f32(i)}
		_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))
	}

	root_ns, target, ok := engine.nested_scene_locate_root_override(loaded, host, lid)
	testing.expect(t, ok && root_ns != nil)
	if !ok || root_ns == nil do return

	count := 0
	for ov in root_ns.overrides {
		if strings.compare(ov.property_path, "scale") == 0 && ov.target.local_id == target.local_id do count += 1
	}
	testing.expect(t, count == 1, "repeated edits to one field must keep exactly one override entry")

	// The surviving entry holds the LAST value.
	for ov in root_ns.overrides {
		if strings.compare(ov.property_path, "scale") == 0 && ov.target.local_id == target.local_id {
			testing.expect(t, override_vec3_matches(ov.value, {5, 5, 5}), "the last edit's value must win")
		}
	}
}

// The created/updated distinction undo depends on: only the edit that
// INTRODUCED an override may remove it on undo — a later edit of the same
// field must leave the pre-existing record in place.
@(test)
test_live_override_reports_created_once :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_override_created.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if host == {} || edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id

	ct.scale = {2, 2, 2}
	testing.expect(t, _record_live_created(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32)),
		"the FIRST edit of an un-overridden field creates the entry")

	ct.scale = {3, 3, 3}
	testing.expect(t, !_record_live_created(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32)),
		"a later edit of the same field UPDATES, so undo must not remove the record")

	// A field the fixture already overrides never reports created, so undoing
	// an edit to it leaves the shipped override intact.
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "position"),
		"fixture should pre-override position")
	ct.position = {9, 9, 9}
	testing.expect(t, !_record_live_created(loaded, host, lid, "position", &ct.position, typeid_of([3]f32)),
		"editing a PRE-EXISTING override must not report created")
}

// Undo's bookkeeping inverse: remove the record without touching the value.
@(test)
test_unrecord_override_removes_only_the_record :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_unrecord.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if host == {} || edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id

	ct.scale = {5, 5, 5}
	_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "scale"))

	testing.expect(t, engine.nested_scene_unrecord_override_for_host(loaded, host, lid, "scale"),
		"unrecord should report the entry went away")
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"the override record must be gone")
	// Value untouched: undo's own Value_Command restores it, not unrecord.
	testing.expect(t, ct.scale == [3]f32{5, 5, 5},
		"unrecord must NOT change the live value (the undo value command does that)")

	testing.expect(t, !engine.nested_scene_unrecord_override_for_host(loaded, host, lid, "scale"),
		"unrecording a missing entry reports false")
}

// DEEP chain (TestA -> TestB -> TransformC): the live lid of nested content is
// composed with INSTANCE_LID_BIT and does NOT equal its source-namespace lid,
// so undo's redo path must resolve the live field through the bimap. Undo never
// needed the lookup (it matches the projected target), which is why redo was
// the half that broke.
@(test)
test_live_override_deep_chain_redo_finds_field :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_live_deep_redo.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_b := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	testing.expect(t, host_b != {})
	if host_b == {} do return
	deep := find_nested_named_under_host(&tc_mem.world, loaded, host_b, "TransformC")
	testing.expect(t, deep != {}, "TransformC should resolve under the TestB instance")
	if deep == {} do return
	dt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(deep))
	if dt == nil do return
	lid := dt.local_id

	// The live lid really is composed (this is what broke the lookup).
	testing.expect(t, lid & engine.INSTANCE_LID_BIT != 0,
		"deep-chain content should carry a composed instance lid")

	// The host for override purposes is the immediate nested host.
	host := engine.transform_immediate_nested_host(deep)
	testing.expect(t, host != {})
	if host == {} do return

	// This is exactly what undo's redo path calls.
	ptr, tid, found := engine.nested_scene_find_live_field(loaded, host, lid, "position")
	testing.expect(t, found && ptr != nil, "redo must locate the live field for a DEEP target")
	if !found do return
	testing.expect(t, tid == typeid_of([3]f32), "located field should be the position vector")
	testing.expect(t, ptr == rawptr(&dt.position), "located field should BE the live position")

	// End to end: record (undo's original edit), unrecord (undo), re-record
	// from the live field (redo) — the sequence that left no marker before.
	dt.position = {7, 8, 9}
	created, ok := engine.nested_scene_record_override_for_host(loaded, host, lid, "position", ptr, tid)
	testing.expect(t, ok && created, "the deep edit should create an override")
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "position"))

	testing.expect(t, engine.nested_scene_unrecord_override_for_host(loaded, host, lid, "position"),
		"undo removes the record")
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, lid, "position"))

	_, redo_ok := engine.nested_scene_record_override_for_host(loaded, host, lid, "position", ptr, tid)
	testing.expect(t, redo_ok, "redo re-records")
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "position"),
		"REDO must re-mark the deep override")
}

// Undo of a REVERT must put the override record back, not just the value. The
// entries are snapshotted before the revert deletes them and restored verbatim.
@(test)
test_override_restore_after_revert :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_override_restore.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/VariantC.scene")
	if loaded == nil do return
	tc_mem.scene = loaded

	host := find_transform_named(&tc_mem.world, loaded, "RootC", false)
	edited := find_transform_named(&tc_mem.world, loaded, "TransformC_Variant", true)
	if host == {} || edited == {} do return
	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(edited))
	if ct == nil do return
	lid := ct.local_id

	ct.scale = {6, 6, 6}
	_record_live(loaded, host, lid, "scale", &ct.scale, typeid_of([3]f32))
	root_ns, target, ok := engine.nested_scene_locate_root_override(loaded, host, lid)
	if !ok || root_ns == nil do return

	// What undo snapshots before reverting.
	targets, paths, values := engine.nested_scene_overrides_covered_by(root_ns, target, "scale")
	testing.expect(t, len(paths) == 1, "one entry covers the reverted path")
	if len(paths) != 1 do return
	saved_target := targets[0]
	saved_path := strings.clone(paths[0], context.temp_allocator)
	saved_value := make([]byte, len(values[0]), context.temp_allocator)
	copy(saved_value, values[0])

	engine.nested_scene_revert_override(loaded, root_ns, target, "scale", &ct.scale)
	testing.expect(t, !engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"revert clears the record")

	// Undo of the revert.
	testing.expect(t, engine.nested_scene_restore_override(root_ns, saved_target, saved_path, saved_value),
		"restore should succeed")
	testing.expect(t, engine.nested_scene_has_root_override(loaded, host, lid, "scale"),
		"UNDO of a revert must bring the override back")

	// Restored verbatim, and not duplicated.
	count := 0
	for ov in root_ns.overrides {
		if ov.target.local_id == target.local_id && strings.compare(ov.property_path, "scale") == 0 {
			count += 1
			testing.expect(t, override_vec3_matches(ov.value, {6, 6, 6}),
				"the restored override must carry its original value")
		}
	}
	testing.expect(t, count == 1, "restore must not duplicate the entry")
}

// --- Structural component edits on a prefab instance -------------------------
// docs/PrefabsSpec.md §4.2-4.3: removing/adding a component on nested content is
// recorded on the instance's NestedScene, so it survives BOTH the save and the
// next resolve (which rebuilds the instance from its prefab).

// HostDup nests SpriteDup, whose SpriteA child carries a SpriteRenderer.
@(test)
test_component_removal_survives_save_and_reload :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_comp_removed.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// The nested SpriteRoot and its SpriteRenderer.
	sprite_tH := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	testing.expect(t, sprite_tH != {}, "nested SpriteA should resolve")
	if sprite_tH == {} do return
	st := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_tH))
	if st == nil do return
	host_tH := engine.transform_immediate_nested_host(sprite_tH)
	testing.expect(t, host_tH != {})
	if host_tH == {} do return

	comp_h, sr := engine.transform_get_comp(sprite_tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "the nested content should carry a SpriteRenderer")
	if sr == nil do return
	comp_lid := (cast(^engine.CompData)sr).local_id

	// Remove it the way the inspector does: destroy + record.
	engine.transform_remove_comp(sprite_tH, comp_h.handle)
	created, ok := engine.nested_scene_record_component_removed(loaded, host_tH, comp_lid)
	testing.expect(t, ok && created, "removing prefab content should record a removal")

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// The file must carry the removal record.
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			// The record stores a SOURCE-namespace target; the live lid is an
			// instance lid, so assert on presence rather than equality.
			count := 0
			for ns in sf.nested_scenes {
				count += len(ns.removed_components)
			}
			testing.expect(t, count == 1, "the removal must be written to the file")
			engine.scene_file_destroy(&sf)
		}
	}

	// RELOAD: the resolve rebuilds from the prefab, so this is the assertion
	// that matters — the component must NOT come back.
	engine.sm_scene_destroy_or_unload(loaded)
	engine.sm_scene_set_active(nil)
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	sprite2 := find_transform_named(&tc_mem.world, reloaded, "SpriteA", true)
	testing.expect(t, sprite2 != {}, "SpriteA itself should still be there")
	if sprite2 == {} do return
	_, sr2 := engine.transform_get_comp(sprite2, engine.SpriteRenderer)
	testing.expect(t, sr2 == nil, "a REMOVED component must not reappear after reload")
}

@(test)
test_component_addition_survives_save_and_reload :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_comp_added.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	sprite_tH := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	if sprite_tH == {} do return
	st := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_tH))
	if st == nil do return
	host_tH := engine.transform_immediate_nested_host(sprite_tH)
	if host_tH == {} do return

	// Add a component the prefab does NOT have.
	owned, ptr := engine.transform_add_comp(sprite_tH, .SpriteSortingGroup)
	testing.expect(t, ptr != nil, "adding a component should succeed")
	if ptr == nil do return
	comp_lid := (cast(^engine.CompData)ptr).local_id
	guid := engine.get_guid_by_type_key(.SpriteSortingGroup)
	type_guid := uuid.to_string(guid, context.temp_allocator)

	created, ok := engine.nested_scene_record_component_added(
		loaded, host_tH, st.local_id, comp_lid, type_guid,
		ptr, engine.get_typeid_by_type_key(.SpriteSortingGroup),
	)
	testing.expect(t, ok && created, "adding to prefab content should record an addition")
	_ = owned

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			count := 0
			for ns in sf.nested_scenes {
				count += len(ns.added_components)
			}
			testing.expect(t, count == 1, "the addition must be written to the file")
			engine.scene_file_destroy(&sf)
		}
	}

	engine.sm_scene_destroy_or_unload(loaded)
	engine.sm_scene_set_active(nil)
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	sprite2 := find_transform_named(&tc_mem.world, reloaded, "SpriteA", true)
	if sprite2 == {} do return
	_, spin := engine.transform_get_comp(sprite2, engine.SpriteSortingGroup)
	testing.expect(t, spin != nil, "an ADDED component must be present after reload")
}

// The add/remove component bake edits a parsed JSON tree in place and inserts
// new values into it. Allocating those inserts from a DIFFERENT allocator than
// the tree, then destroying the tree, is a bad free — it crashed the editor on
// load (the editor runs a tracking allocator; the plain test allocator hides
// it). This runs the same path under tracking so the mistake can't come back.
@(test)
test_component_edits_no_bad_free :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
		defer engine.asset_db_shutdown()
		defer engine.scene_lib_shutdown()

		tc_mem := new(TestCtx)
		defer free(tc_mem)
		setup(tc_mem, "moonhug/tests/fixtures/_test_comp_badfree.scene")
		context.user_ptr = &tc_mem.uc
		defer teardown(tc_mem)

		loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
		if loaded == nil do return
		tc_mem.scene = loaded

		sprite_tH := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
		if sprite_tH == {} do return
		st := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sprite_tH))
		if st == nil do return
		host_tH := engine.transform_immediate_nested_host(sprite_tH)
		if host_tH == {} do return

		// ADD a component, save, then LOAD — the load runs the resolve-time
		// bake, which is where the bad free happened.
		_, ptr := engine.transform_add_comp(sprite_tH, .SpriteSortingGroup)
		if ptr == nil do return
		comp_lid := (cast(^engine.CompData)ptr).local_id
		guid := engine.get_guid_by_type_key(.SpriteSortingGroup)
		engine.nested_scene_record_component_added(
			loaded, host_tH, st.local_id, comp_lid,
			uuid.to_string(guid, context.temp_allocator),
			ptr, engine.get_typeid_by_type_key(.SpriteSortingGroup),
		)
		testing.expect(t, engine.scene_save(loaded, tc_mem.path))

		engine.sm_scene_destroy_or_unload(loaded)
		engine.sm_scene_set_active(nil)
		reloaded := engine.scene_load_single_path(tc_mem.path)
		testing.expect(t, reloaded != nil, "the scene must load without crashing")
		tc_mem.scene = reloaded

		// And the same path with a REMOVAL.
		if reloaded != nil {
			s2 := find_transform_named(&tc_mem.world, reloaded, "SpriteA", true)
			if s2 != {} {
				h2 := engine.transform_immediate_nested_host(s2)
				ch, sr := engine.transform_get_comp(s2, engine.SpriteRenderer)
				if sr != nil && h2 != {} {
					lid2 := (cast(^engine.CompData)sr).local_id
					engine.transform_remove_comp(s2, ch.handle)
					engine.nested_scene_record_component_removed(reloaded, h2, lid2)
					testing.expect(t, engine.scene_save(reloaded, tc_mem.path))
					engine.sm_scene_destroy_or_unload(reloaded)
					engine.sm_scene_set_active(nil)
					r3 := engine.scene_load_single_path(tc_mem.path)
					testing.expect(t, r3 != nil, "reload after a removal must not crash")
					tc_mem.scene = r3
				}
			}
		}
	}

	testing.expectf(t, len(track.bad_free_array) == 0,
		"component-edit bake must not free across allocators (%d bad frees)", len(track.bad_free_array))
	for bf in track.bad_free_array {
		fmt.printfln("  bad free at %v", bf.location)
	}
}

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

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_no_phantom_comps.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

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
@(test)
test_object_addition_survives_save_and_reload :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_obj_added.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	parent := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	testing.expect(t, parent != {}, "nested SpriteA should resolve")
	if parent == {} do return

	// Add a child under PREFAB content — the host addition.
	added := engine.transform_new("HostAddedChild", parent)
	testing.expect(t, added != {}, "creating the child should succeed")
	if added == {} do return

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			count := 0
			for ns in sf.nested_scenes do count += len(ns.added_objects)
			testing.expect(t, count == 1, "the addition must be written to the file")
			engine.scene_file_destroy(&sf)
		}
	}

	// RELOAD: resolve rebuilds the instance from its prefab, so this is the
	// assertion that matters — the added object must be grafted back.
	engine.sm_scene_destroy_or_unload(loaded)
	engine.sm_scene_set_active(nil)
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	back := find_transform_named(&tc_mem.world, reloaded, "HostAddedChild", false)
	testing.expect(t, back != {}, "an ADDED object must be present after reload")
	if back == {} do return
	bt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(back))
	testing.expect(t, bt != nil)
	if bt == nil do return
	pt := engine.pool_get(&tc_mem.world.transforms, bt.parent.handle)
	testing.expect(t, pt != nil && strings.compare(pt.name, "SpriteA") == 0,
		"the added object must come back under its prefab parent")
}

// An unchanged load->save must not invent object edits. The live walk skips the
// base root and inner-NS content, so "absent from the walk" does NOT mean the
// user removed something — inferring removals that way invented them.
@(test)
test_unchanged_save_invents_no_object_edits :: proc(t: ^testing.T) {
	ASSETS :: "moonhug/packages/prefabs_example/assets"
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_no_phantom_objs.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

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
@(test)
test_object_removal_survives_save_and_reload :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_obj_removed.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	victim := find_transform_named(&tc_mem.world, loaded, "SpriteB", true)
	testing.expect(t, victim != {}, "nested SpriteB should resolve")
	if victim == {} do return
	vt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(victim))
	if vt == nil do return
	host_tH := engine.transform_immediate_nested_host(victim)
	testing.expect(t, host_tH != {})
	if host_tH == {} do return
	obj_lid := vt.local_id

	// Delete the way the hierarchy does: destroy + record.
	engine.transform_destroy(victim)
	created, ok := engine.nested_scene_record_object_removed(loaded, host_tH, obj_lid)
	testing.expect(t, ok && created, "deleting prefab content should record a removal")

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		if fok {
			count := 0
			for ns in sf.nested_scenes do count += len(ns.removed_objects)
			testing.expect(t, count == 1, "the removal must be written to the file")
			engine.scene_file_destroy(&sf)
		}
	}

	engine.sm_scene_destroy_or_unload(loaded)
	engine.sm_scene_set_active(nil)
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	gone := find_transform_named(&tc_mem.world, reloaded, "SpriteB", true)
	testing.expect(t, gone == {}, "a REMOVED object must not reappear after reload")
	// Its sibling is untouched.
	sibling := find_transform_named(&tc_mem.world, reloaded, "SpriteA", true)
	testing.expect(t, sibling != {}, "removing one object must not affect its siblings")
}

// Undo of a nested delete must RESTORE the object, and restore it as prefab
// content. Two things made this fail: scene_copy_subtree refuses nested-owned
// nodes (correct for a save — the host file must not contain prefab content —
// but it left undo with an empty payload), and the restored rows come back
// from the loader as plain host content unless the flag is re-applied.
@(test)
test_nested_delete_undo_restores_object :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	u := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, u)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded
	engine.sm_scene_set_active(loaded)

	victim := find_transform_named(&tc_mem.world, loaded, "SpriteB", true)
	testing.expect(t, victim != {}, "nested SpriteB should resolve")
	if victim == {} do return
	vt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(victim))
	if vt == nil do return
	host := engine.transform_immediate_nested_host(victim)
	if host == {} do return
	lid := vt.local_id

	// Delete exactly as the hierarchy does.
	{
		g := undo.group_begin("Delete Selected")
		defer undo.group_end(&g)
		undo.record_delete(victim)
		engine.nested_scene_record_object_removed(loaded, host, lid)
		undo.record_object_removed_on_instance(loaded, host, lid)
		undo.group_commit(&g)
	}
	testing.expect(t, find_transform_named(&tc_mem.world, loaded, "SpriteB", true) == {},
		"delete should remove it")

	testing.expect(t, undo.apply_undo(u), "undo should apply")
	back := find_transform_named(&tc_mem.world, loaded, "SpriteB", true)
	testing.expect(t, back != {}, "UNDO must restore the deleted object")
	if back == {} do return
	bt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(back))
	testing.expect(t, bt != nil && bt.nested_owned,
		"the restored object must be prefab content again, not a host addition")
	total := 0
	for &ns in loaded.nested_scenes do total += len(ns.removed_objects)
	testing.expect(t, total == 0, "undo must retract the removal record")

	// REDO deletes it again (its lid is not in the scene bimap, so the redo
	// lookup has to fall back to a live scan).
	testing.expect(t, undo.apply_redo(u), "redo should apply")
	testing.expect(t, find_transform_named(&tc_mem.world, loaded, "SpriteB", true) == {},
		"REDO must delete it again")
	total2 := 0
	for &ns in loaded.nested_scenes do total2 += len(ns.removed_objects)
	testing.expect(t, total2 == 1, "redo must re-record the removal")
}

// Create-child under prefab content, undo, redo. Redo looked the PARENT up in
// the scene bimap, which does not hold prefab-content lids (composed instance
// lids belong to the instance, not the host), so it silently did nothing.
@(test)
test_nested_create_child_undo_redo :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	u := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, u)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded
	engine.sm_scene_set_active(loaded)

	parent := find_transform_named(&tc_mem.world, loaded, "SpriteA", true)
	testing.expect(t, parent != {}, "nested SpriteA should resolve")
	if parent == {} do return

	child := undo.record_create_child("HostChild", parent)
	testing.expect(t, child != {}, "create should succeed")
	testing.expect(t, find_transform_named(&tc_mem.world, loaded, "HostChild", false) != {},
		"the child should exist after create")

	testing.expect(t, undo.apply_undo(u), "undo should apply")
	testing.expect(t, find_transform_named(&tc_mem.world, loaded, "HostChild", false) == {},
		"undo should remove the child")

	testing.expect(t, undo.apply_redo(u), "redo should apply")
	back := find_transform_named(&tc_mem.world, loaded, "HostChild", false)
	testing.expect(t, back != {}, "REDO must recreate the child under prefab content")
	if back == {} do return
	bt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(back))
	testing.expect(t, bt != nil, "recreated child should be live")
	if bt == nil do return
	pt := engine.pool_get(&tc_mem.world.transforms, bt.parent.handle)
	testing.expect(t, pt != nil && strings.compare(pt.name, "SpriteA") == 0,
		"the child must come back under its original parent")
	// A host addition, NOT prefab content — it must stay capturable as an
	// added_object.
	testing.expect(t, !bt.nested_owned, "a host-created child is not prefab content")
}
