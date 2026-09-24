package tests

// One selection for the whole editor (editor/selection.odin): selecting a scene
// object deselects project files and the other way round, the Inspector keeps
// the objects it showed while the project holds the selection, and an
// operation that selects what it made (a create) records that selection in
// its own undo step, so one undo restores what was selected before.

import "core:os"
import "core:testing"
import "../editor"
import "../editor/undo"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"

// Every test here touches editor-wide selection state, so each starts and ends
// from nothing.
@(private = "file")
_selection_reset :: proc() {
	editor.sel_scene_clear()
	editor.sel_proj_clear()
	editor.selection_undo_shutdown()
}

@(test)
test_selecting_an_asset_deselects_objects_and_keeps_the_inspector :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()

	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.sel_proj_only("assets/Some.mat")

	testing.expect_value(t, editor.sel_scene_count(), 0)
	testing.expect_value(t, editor.sel_proj_count(), 1)
	testing.expect(t, editor.sel_in_project(), "the selection lives in the project")
	inspected := editor.sel_scene_inspected()
	testing.expect(t, len(inspected) == 1 && inspected[0] == a, "the Inspector keeps the object it showed")

	// Back to an object: the file is deselected, the kept object is replaced.
	b := engine.transform_new("B")
	editor.sel_scene_only(b)
	testing.expect_value(t, editor.sel_proj_count(), 0)
	testing.expect(t, !editor.sel_in_project(), "the selection lives in the scene")
	inspected = editor.sel_scene_inspected()
	testing.expect(t, len(inspected) == 1 && inspected[0] == b, "the Inspector shows the live selection")
}

// Clearing is not a move to the other set: an explicit clear empties the
// Inspector, and clearing one set leaves the other.
@(test)
test_clearing_one_set_leaves_the_other :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()

	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.sel_proj_only("assets/Some.mat")
	editor.sel_scene_clear()
	testing.expect_value(t, len(editor.sel_scene_inspected()), 0)
	testing.expect_value(t, editor.sel_proj_count(), 1)

	editor.sel_scene_only(a)
	editor.sel_proj_clear()
	testing.expect_value(t, editor.sel_scene_count(), 1)
}

// Create Empty selects what it made, and the selection is part of the create's
// undo step: one undo removes the object AND restores the old selection, redo
// brings both back. Before, the change landed in the same frame as the create
// and was never recorded, so undo left nothing selected.
@(test)
test_create_selects_and_one_undo_restores_the_old_selection :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	editor.selection_undo_install()
	_selection_reset()
	defer _selection_reset()

	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.selection_undo_track() // first frame: baseline only
	entries_before := len(s.items)

	editor.hierarchy_create_empty_menu()
	editor.selection_undo_track() // the same frame's end: attaches the selection
	testing.expect_value(t, len(s.items), entries_before + 1)
	created := editor.sel_scene_active()
	testing.expect(t, created != a && created != {}, "the new object is selected")

	testing.expect(t, undo.apply_undo(s), "undo")
	editor.selection_undo_track()
	testing.expect(t, editor.sel_scene_count() == 1 && editor.sel_scene_active() == a, "one undo restores the old selection")

	testing.expect(t, undo.apply_redo(s), "redo")
	editor.selection_undo_track()
	w := engine.ctx_world()
	active := editor.sel_scene_active()
	t_new := engine.pool_get(&w.transforms, engine.Handle(active))
	testing.expect(t, active != a && t_new != nil && t_new.name == "Transform", "redo selects the object again")
}

// A plain click is still its own step, and undoing it moves the selection
// back across sets: an asset click undone reselects the object.
@(test)
test_undo_of_an_asset_click_reselects_the_object :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_selection_tmp"
	path :: src_dir + "/cube.glb"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/cube.glb", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(path, bytes) == nil)
	defer {
		_remove_tree(src_dir)
		_remove_tree("library")
	}

	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	editor.selection_undo_install()
	_selection_reset()
	defer _selection_reset()

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	_, registered := engine.asset_db_get_guid(path)
	testing.expect(t, registered, "the fixture is registered, so the snapshot can store its guid")
	if !registered do return

	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.selection_undo_track() // baseline
	entries := len(s.items)

	editor.sel_proj_only(path)
	editor.selection_undo_track()
	testing.expect(t, editor.sel_in_project(), "the click moved the selection to the project")
	testing.expect_value(t, len(s.items), entries + 1)

	testing.expect(t, undo.apply_undo(s), "undo")
	editor.selection_undo_track()
	testing.expect(t, editor.sel_scene_active() == a && editor.sel_proj_count() == 0, "undo reselects the object and deselects the file")
}

// Undo restores what the Inspector showed, not only the selection: undoing a
// create made while an asset was selected reselects the asset AND brings the
// Inspector back to the object it kept. Before, the Inspector went blank.
@(test)
test_undo_restores_the_inspectors_kept_object :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_selection_kept_tmp"
	path :: src_dir + "/cube.glb"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/cube.glb", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(path, bytes) == nil)
	defer {
		_remove_tree(src_dir)
		_remove_tree("library")
	}

	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	editor.selection_undo_install()
	_selection_reset()
	defer _selection_reset()

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	if _, ok := engine.asset_db_get_guid(path); !ok {
		testing.expect(t, false, "the fixture is registered")
		return
	}

	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.selection_undo_track()
	editor.sel_proj_only(path)
	editor.selection_undo_track()
	testing.expect(t, editor.sel_scene_inspected_active() == a, "the Inspector keeps A while the asset is selected")

	editor.hierarchy_create_empty_menu()
	editor.selection_undo_track()

	testing.expect(t, undo.apply_undo(s), "undo the create")
	editor.selection_undo_track()
	testing.expect(t, editor.sel_in_project(), "the asset is selected again")
	testing.expect(t, editor.sel_scene_inspected_active() == a, "the Inspector shows A again")
}
