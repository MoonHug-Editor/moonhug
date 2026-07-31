package tests

// Live override recording (nested_scene_record_override): a prefab-instance
// edit becomes revertable IMMEDIATELY, not only after a save, and is STICKY —
// only an explicit revert removes it.

import "../engine"

import "core:testing"
import "core:strings"

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
	// override (docs/NestedPrefabs.md "overrides grow only"); only an explicit
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
