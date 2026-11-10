package engine_tests

// One selection for the whole editor (editor/selection.odin): selecting a scene
// object deselects project files and the other way round, the Inspector keeps
// the objects it showed while the project holds the selection, and an
// operation that selects what it made (a create) records that selection in
// its own undo step, so one undo restores what was selected before.

import "core:os"
import "core:testing"
import "moonhug:editor"
import "moonhug:editor/undo"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine/editor/scene_windows"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"

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

	scene_windows.hierarchy_create_empty_menu()
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
		_remove_tree(engine.library_dir())
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
		_remove_tree(engine.library_dir())
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

	scene_windows.hierarchy_create_empty_menu()
	editor.selection_undo_track()

	testing.expect(t, undo.apply_undo(s), "undo the create")
	editor.selection_undo_track()
	testing.expect(t, editor.sel_in_project(), "the asset is selected again")
	testing.expect(t, editor.sel_scene_inspected_active() == a, "the Inspector shows A again")
}

// Each Inspector instance has its own lock: a locked instance keeps the
// objects it showed while the others follow the selection, and a closed
// instance's lock goes with it.
@(test)
test_inspector_instances_lock_apart :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()
	defer editor.window_locks_shutdown()

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	editor.sel_scene_only(a)
	editor.window_lock_set("Inspector/2", true)
	editor.sel_scene_only(b)

	first := editor.window_objects("Inspector")
	second := editor.window_objects("Inspector/2")
	testing.expect(t, len(first) == 1 && first[0] == b, "the first Inspector follows the selection")
	testing.expect(t, len(second) == 1 && second[0] == a, "the locked Inspector keeps A")
	testing.expect(t, editor.window_object("Inspector/2") == a, "the locked Inspector draws A")

	// No window is open under "Inspector/2", so the prune drops its lock.
	editor.window_locks_prune()
	second = editor.window_objects("Inspector/2")
	testing.expect(t, len(second) == 1 && second[0] == b, "a closed Inspector's lock is gone")
}

// A request every Hierarchy copy follows reaches all of them: scrolling to
// the selection, and unfolding the ancestors of an object to reveal.
@(test)
test_hierarchy_requests_reach_every_copy :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	if !wnd.is_registered(scene_windows.HIERARCHY) {
		wnd.register(scene_windows.HIERARCHY, "Hierarchy", "X", scene_windows.hierarchy_window_draw, 0, 0, closed = scene_windows.hierarchy_window_closed)
	}
	first := wnd.open(scene_windows.HIERARCHY)
	second := wnd.open_another(scene_windows.HIERARCHY)
	defer {
		wnd.close(first.key)
		wnd.close(second.key)
		wnd.draw_all()
	}

	scene_windows.hierarchy_scroll_to_selection()
	a := (^scene_windows.Hierarchy_Window)(first.data)
	b := (^scene_windows.Hierarchy_Window)(second.data)
	testing.expect(t, a != nil && b != nil && a != b, "each copy has its own state")
	if a == nil || b == nil do return
	testing.expect(t, a.scroll_to_sel && b.scroll_to_sel, "both copies scroll to the selection")

	parent := engine.transform_new("Parent")
	child := engine.transform_new("Child", parent)
	session.hierarchy_reveal(child)
	testing.expect(t, a.alt_open_pending[parent] && b.alt_open_pending[parent], "both copies unfold the object's parent")
}

// The selection and an Inspector lock survive a restart: saved as scene
// asset and local id, they resolve back to the same objects, in click order
// with the active one last, and the restore records no undo step. An object
// gone since the save drops out.
@(test)
test_selection_and_inspector_lock_survive_a_restart :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	_selection_reset()
	defer _selection_reset()
	defer editor.window_lock_set("Inspector", false)
	defer editor.selection_persist_set_restored_for_test(false)

	scene := engine.sm_scene_get_active()
	if !testing.expect(t, scene != nil, "a scene is active") do return
	scene.asset_guid = engine.Asset_GUID{0 = 0x5E, 15 = 0x01}

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	c := engine.transform_new("C")
	editor.sel_scene_only(b)
	editor.sel_scene_add(a)
	editor.window_lock_set("Inspector", true)
	editor.sel_scene_only(c)
	editor.sel_scene_add(a)

	editor.selection_persist_set_restored_for_test(true)
	editor.selection_persist_capture()
	testing.expect_value(t, len(editor.editor_settings.selection.objects), 2)
	// One window holds a lock. The list also has the windows that only save
	// their state.
	lock_count := 0
	for w in editor.editor_settings.windows do if len(w.objects) > 0 || len(w.assets) > 0 do lock_count += 1
	testing.expect_value(t, lock_count, 1)

	// Next run: nothing selected, nothing locked, C deleted meanwhile.
	editor.window_lock_set("Inspector", false)
	editor.sel_scene_clear()
	engine.transform_destroy(c)
	editor.selection_undo_track()
	before := s.top

	editor.selection_persist_set_restored_for_test(false)
	editor.selection_persist_restore()
	items := editor.sel_scene_items()
	testing.expect(t, len(items) == 1 && items[0] == a, "the selection is back, without the deleted object")
	locked := editor.window_objects("Inspector")
	testing.expect(t, len(locked) == 2 && locked[0] == b && locked[1] == a, "the Inspector lock holds its objects again")

	editor.selection_undo_track()
	editor.selection_undo_track()
	testing.expect_value(t, s.top, before)
}

// The tool windows (Animation, Playable Graph, Sequencer) follow the
// selection, not a locked Inspector: with the Inspector locked to A, selecting
// B publishes B. Selecting an asset keeps B, the object the Inspector kept.
@(test)
test_tool_windows_follow_the_selection_not_a_locked_inspector :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()
	defer editor.window_lock_set("Inspector", false)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	editor.sel_scene_only(a)
	editor.window_lock_set("Inspector", true)
	editor.sel_scene_only(b)
	editor.selection_publish()
	testing.expect_value(t, engine.inspector_inspected_selection(), b)
	testing.expect_value(t, editor.window_object("Inspector"), a)

	editor.sel_proj_only("assets/Some.mat")
	editor.selection_publish()
	testing.expect_value(t, engine.inspector_inspected_selection(), b)
}

// A lock holds references, not handles. While its scene is not loaded the
// locked object is missing: the window stays locked and says so. Once a scene
// with that asset is loaded the same object shows again. A restored lock
// waits for its window however late the window opens, and the lock goes only
// when its window closes after having been open.
@(test)
test_window_lock_waits_for_missing_objects_and_windows :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()
	defer editor.window_locks_shutdown()

	scene := engine.sm_scene_get_active()
	if !testing.expect(t, scene != nil, "a scene is active") do return
	a := engine.transform_new("A")
	w := engine.ctx_world()
	lid := engine.pool_get(&w.transforms, engine.Handle(a)).local_id
	guid := engine.Asset_GUID{0 = 0x10, 15 = 0x07}

	// Restored for a window not open yet, naming a scene not loaded yet.
	editor.window_lock_restore("Inspector/7", {{scene_guid = guid, local_id = lid}}, {})
	editor.window_locks_prune()
	testing.expect(t, editor.window_locked("Inspector/7"), "a restored lock waits for its window")
	testing.expect(t, editor.window_lock_missing("Inspector/7"), "its object is missing while its scene is not loaded")
	testing.expect_value(t, len(editor.window_objects("Inspector/7")), 0)

	// The scene is back: the same object shows.
	scene.asset_guid = guid
	testing.expect(t, !editor.window_lock_missing("Inspector/7"), "the object is back")
	testing.expect_value(t, editor.window_object("Inspector/7"), a)
}

// Locking takes both sets of the selection, the kept ones included: with an
// object selected after an asset, the lock holds the object and the asset
// the Project windows keep showing, with its sub-asset id.
@(test)
test_window_lock_takes_kept_assets_with_their_sub_ids :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_selection_reset()
	defer _selection_reset()
	defer editor.window_locks_shutdown()

	a := engine.transform_new("A")
	editor.sel_proj_only("moonhug/tests", 42)
	editor.sel_scene_only(a)
	kept := editor.sel_proj_inspected()
	testing.expect(t, len(kept) == 1 && kept[0].path == "moonhug/tests" && kept[0].sub_id == 42, "the scene selection keeps the asset")

	editor.window_lock_set("Project Inspector", true)
	editor.sel_scene_clear()
	editor.sel_proj_clear()
	held := editor.window_assets("Project Inspector")
	testing.expect(t, len(held) == 1 && held[0].path == "moonhug/tests" && held[0].sub_id == 42, "the lock holds the kept asset and its sub id")
	testing.expect_value(t, editor.window_object("Project Inspector"), a)
	testing.expect_value(t, len(editor.window_assets("Inspector")), 0)
}

// A window whose instances share one lock: every instance key names the
// window's lock.
@(test)
test_window_lock_key_of_a_shared_lock :: proc(t: ^testing.T) {
	ID :: "_Shared_Lock_Test"
	if wnd.lock_mode(ID) == .None {
		wnd.register(ID, ID, "X", proc(w: ^wnd.Window) {}, 0, 0, lock = .Shared)
	}
	testing.expect_value(t, editor.window_lock_key(ID + "/3"), ID)
	testing.expect_value(t, editor.window_lock_key("Inspector/2"), "Inspector/2")
}

// The assets the Project Inspector keeps while an object is selected come
// back with the saved selection after a restart, as the kept objects do.
@(test)
test_kept_assets_survive_a_restart :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_selection_kept_tmp"
	path :: src_dir + "/cube.glb"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/cube.glb", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(path, bytes) == nil)
	defer {
		_remove_tree(src_dir)
		_remove_tree(engine.library_dir())
	}

	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	editor.selection_undo_install()
	_selection_reset()
	defer _selection_reset()
	defer editor.selection_persist_set_restored_for_test(false)

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	if _, registered := engine.asset_db_get_guid(path); !testing.expect(t, registered, "the fixture is registered") do return

	scene := engine.sm_scene_get_active()
	if !testing.expect(t, scene != nil, "a scene is active") do return
	scene.asset_guid = engine.Asset_GUID{0 = 0x6B, 15 = 0x03}
	a := engine.transform_new("A")

	editor.sel_proj_only(path)
	editor.selection_undo_track() // baseline
	editor.sel_scene_only(a)
	editor.selection_undo_track()
	kept := editor.sel_proj_inspected()
	testing.expect(t, len(kept) == 1 && kept[0].path == path, "the object click keeps the asset")

	// Saved, cleared, restored.
	editor.selection_persist_set_restored_for_test(true)
	editor.selection_persist_capture()
	testing.expect_value(t, len(editor.editor_settings.selection.kept_assets), 1)
	editor.sel_scene_clear()
	editor.sel_proj_clear()
	editor.selection_persist_set_restored_for_test(false)
	editor.selection_persist_restore()
	kept = editor.sel_proj_inspected()
	testing.expect(t, len(kept) == 1 && kept[0].path == path, "the restart keeps the asset")
	items := editor.sel_scene_items()
	testing.expect(t, len(items) == 1 && items[0] == a, "and the object stays selected")
}

