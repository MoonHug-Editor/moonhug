package tests

// Prefab Apply as an undo step (undo.apply_to_prefab): undo writes the prefab
// file's old bytes back and restores the instance's records, redo applies
// again, and a file changed on disk since the Apply is left as it is.

import "core:encoding/uuid"
import "core:os"
import "core:testing"
import "../editor/undo"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"

@(test)
test_prefab_apply_undoes_and_redoes :: proc(t: ^testing.T) {
	prefab_path := "moonhug/tests/fixtures/nested_scenes/SpriteDup.scene"
	host_path := "moonhug/tests/fixtures/_test_prefab_apply_undo.scene"
	orig, read_err := os.read_entire_file(prefab_path, context.allocator)
	testing.expect(t, read_err == nil, "reads the SpriteDup.scene fixture")
	if read_err != nil do return
	defer {
		_ = os.write_entire_file(prefab_path, orig)
		delete(orig)
		os.remove(host_path)
	}

	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	// An instance with a field override and an added component, saved and
	// reloaded so both are records on the instance (same shape as
	// test_apply_entries_shallow_field_and_added_component).
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	sprite_tH := find_transform_named(&tc.world, loaded, "SpriteA", true)
	st := engine.pool_get(&tc.world.transforms, engine.Handle(sprite_tH))
	inner_host := engine.transform_immediate_nested_host(sprite_tH)
	testing.expect(t, st != nil && inner_host != {}, "finds SpriteA inside the instance")
	if st == nil || inner_host == {} do return
	want_pos := [3]f32{7, 8, 9}
	st.position = want_pos
	_, comp_ptr := engine.transform_add_comp(sprite_tH, .SpriteSortingGroup)
	testing.expect(t, comp_ptr != nil, "adds the component")
	if comp_ptr == nil do return
	comp_lid := (cast(^engine.CompData)comp_ptr).local_id
	type_guid := uuid.to_string(engine.get_guid_by_type_key(.SpriteSortingGroup), context.temp_allocator)
	_, rec_ok := engine.nested_scene_record_component_added(
		loaded, inner_host, st.local_id, comp_lid, type_guid,
		comp_ptr, engine.get_typeid_by_type_key(.SpriteSortingGroup),
	)
	testing.expect(t, rec_ok)
	testing.expect(t, engine.scene_save(loaded, host_path))
	scene := engine.scene_load_single_path(host_path)
	testing.expect(t, scene != nil, "reloads the saved host scene")
	if scene == nil do return

	native_ns: ^engine.NestedScene
	for &ns_it in scene.nested_scenes {
		if ns_it.expand_parent == {} {
			native_ns = &ns_it
			break
		}
	}
	testing.expect(t, native_ns != nil, "finds the instance record")
	if native_ns == nil do return
	host_tH := engine.Transform_Handle(engine.nested_scene_resolve_host_handle(scene, native_ns))
	overrides_before := len(native_ns.overrides)
	testing.expect(t, overrides_before > 0 && len(native_ns.added_components) == 1, "the instance records both")
	entries := engine.nested_scene_list_overrides(scene, native_ns)
	targets := engine.nested_scene_apply_targets_common(scene, native_ns, entries)
	testing.expect_value(t, len(targets), 1)
	if len(targets) != 1 do return

	testing.expect(t, undo.apply_to_prefab(scene, host_tH, targets[0].guid, entries), "Apply runs")
	testing.expect_value(t, len(s.items), 1)
	applied, _ := os.read_entire_file(prefab_path, context.allocator)
	defer delete(applied)
	testing.expect(t, string(applied) != string(orig), "Apply wrote the prefab")

	testing.expect(t, undo.apply_undo(s), "undo")
	now, _ := os.read_entire_file(prefab_path, context.temp_allocator)
	testing.expect(t, string(now) == string(orig), "undo writes the prefab's old bytes back")
	ns := engine.scene_find_nested_scene_for_host(scene, host_tH)
	testing.expect(t, ns != nil && len(ns.overrides) == overrides_before && len(ns.added_components) == 1, "undo restores the instance's records")
	sprite_tH = find_transform_named(&tc.world, scene, "SpriteA", true)
	if st = engine.pool_get(&tc.world.transforms, engine.Handle(sprite_tH)); st != nil {
		testing.expect(t, st.position == want_pos, "the instance keeps its overridden value")
	}

	testing.expect(t, undo.apply_redo(s), "redo")
	now, _ = os.read_entire_file(prefab_path, context.temp_allocator)
	testing.expect(t, string(now) == string(applied), "redo applies again")
	ns = engine.scene_find_nested_scene_for_host(scene, host_tH)
	testing.expect(t, ns != nil && len(ns.overrides) == 0 && len(ns.added_components) == 0, "redo drops the records again")

	// Changed on disk since the Apply: undo leaves the file alone.
	edited := "{}"
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]u8)edited) == nil)
	undo.apply_undo(s)
	now, _ = os.read_entire_file(prefab_path, context.temp_allocator)
	testing.expect(t, string(now) == edited, "a file changed on disk is not overwritten")
}
