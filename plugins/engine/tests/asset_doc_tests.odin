package engine_tests

// Asset documents (editor/inspector/asset_docs.odin) live as long as their
// asset: deleting the asset drops its document and undo steps, and a save
// writes to where the asset is now. Before, a deleted material with unsaved
// edits came back on the next File/Save, without its .meta, as a new asset.

import "base:runtime"
import "core:os"
import "core:testing"
import "core:path/filepath"
import "core:strings"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/undo"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_asset_doc_tmp"

@(private = "file")
_MAT :: `{
  "__type_guid": "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4",
  "shader": 1,
  "color": [1.0, 1.0, 1.0, 1.0]
}`

// A fixture material, registered, with one undo step and unsaved edits.
@(private = "file")
_edited_material :: proc(t: ^testing.T, s: ^undo.Undo_Stack, path: string) -> ^inspector.Asset_Doc {
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(_MAT)) == nil)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)

	doc := inspector.asset_doc_get(path)
	testing.expect(t, doc != nil, "the material loads as a document")
	if doc == nil do return nil
	sess := undo.edit_session_begin({undo.edit_target_asset(doc.guid, doc.data.id)}, "Color")
	(^engine.Material)(doc.data.data).color = {1, 0, 0, 1}
	undo.edit_session_end(&sess)
	doc.dirty = true
	testing.expect_value(t, len(s.items), 1)
	return doc
}

@(test)
test_deleting_an_asset_drops_its_document_and_undo_steps :: proc(t: ^testing.T) {
	path :: _DIR + "/Doomed.mat"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	if _edited_material(t, s, path) == nil do return
	inspector.load_from_file(path) // the Project Inspector shows it

	testing.expect(t, os.remove(path) == nil)
	os.remove(path + ".meta")
	asset_pipeline.asset_db_refresh()

	testing.expect_value(t, len(s.items), 0)
	testing.expect(t, inspector.inspectorData.doc == nil && inspector.inspectorData.filePath == "", "the inspector lets go of the deleted file")
	saved, failed := inspector.asset_docs_save_dirty()
	testing.expect(t, saved == 0 && failed == 0, "nothing is left to save")
	testing.expect(t, !os.exists(path), "the deleted file stays deleted")
}

// A rename keeps the document (same guid) and its undo steps, and the save
// writes the new path, not the old one.
@(test)
test_saving_a_renamed_asset_writes_its_new_path :: proc(t: ^testing.T) {
	old_path :: _DIR + "/Before.mat"
	new_path :: _DIR + "/After.mat"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	if _edited_material(t, s, old_path) == nil do return

	testing.expect(t, os.rename(old_path, new_path) == nil)
	testing.expect(t, os.rename(old_path + ".meta", new_path + ".meta") == nil)
	asset_pipeline.asset_db_refresh()

	testing.expect_value(t, len(s.items), 1)
	saved, failed := inspector.asset_docs_save_dirty()
	testing.expect(t, saved == 1 && failed == 0, "the renamed asset saves")
	testing.expect(t, os.exists(new_path), "saved at the new path")
	testing.expect(t, !os.exists(old_path), "the old path is not written back")
}

// A file deleted outside the editor, before any refresh noticed: the save
// refuses instead of writing the file back.
@(test)
test_saving_an_asset_deleted_on_disk_does_not_write_it_back :: proc(t: ^testing.T) {
	path :: _DIR + "/External.mat"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	if _edited_material(t, s, path) == nil do return

	testing.expect(t, os.remove(path) == nil)
	saved, failed := inspector.asset_docs_save_dirty()
	testing.expect(t, saved == 0 && failed == 1, "the save reports the missing file")
	testing.expect(t, !os.exists(path), "the file is not written back")
}

// Discard puts the file's values back for good: the document is clean, the
// inspector follows the new instance, and the asset's undo steps are gone, so
// nothing brings the dropped edit back. The test reaches the document the way
// the tab menu does, through the Project Inspector's open document, and checks
// the stars the tab and the project window show.
@(test)
test_discard_restores_the_file_for_good :: proc(t: ^testing.T) {
	path :: _DIR + "/Discarded.mat"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()
	defer inspector.unload()

	doc := _edited_material(t, s, path)
	if doc == nil do return
	inspector.load_from_file(path)

	d, ok := session.view_document("Project Inspector")
	testing.expect(t, ok && d.dirty && d.key == doc, "the Project Inspector's document is the edited material")
	testing.expect(t, strings.contains(string(session.view_title(icons.TITLE_PROJECT_INSPECTOR)), " *###"), "its tab carries a star")
	clean, _ := filepath.clean(path, context.temp_allocator)
	testing.expect(t, clean in session.documents_dirty_paths(), "the project window marks the file")

	session.document_discard(d)
	testing.expect(t, !doc.dirty, "discard leaves the document clean")
	testing.expect_value(t, (^engine.Material)(doc.data.data).color, [4]f32{1, 1, 1, 1})
	testing.expect_value(t, len(s.items), 0)
	testing.expect(t, inspector.inspectorData.fileData.data == doc.data.data, "the inspector follows the new instance")
	testing.expect(t, session.view_title(icons.TITLE_PROJECT_INSPECTOR) == icons.TITLE_PROJECT_INSPECTOR, "the star goes")
}

// File/Save writes every document with unsaved changes, an asset edited
// outside the Project Inspector included.
@(test)
test_save_all_writes_every_dirty_document :: proc(t: ^testing.T) {
	path :: _DIR + "/SavedAll.mat"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	doc := _edited_material(t, s, path)
	if doc == nil do return
	saved, failed := session.documents_save_all()
	testing.expect(t, saved >= 1 && failed == 0, "the material is saved")
	testing.expect(t, !doc.dirty, "and clean")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil && strings.contains(string(data), "[1.0, 0.0, 0.0, 1.0]"), "the file holds the edit: %s", string(data))
}

// "+ Add" and "x" on a dynamic array of an asset shown in the Project
// Inspector: each grows or shrinks the document's array as one undo step, and
// undo puts it back. The array buttons used to take their undo target only
// from a component, so in an asset they did nothing.
@(test)
test_asset_array_add_and_remove_undo :: proc(t: ^testing.T) {
	path :: _DIR + "/Arrays.renderpipeline"
	os.make_directory(_DIR)
	defer {
		_remove_tree(_DIR)
		_remove_tree(engine.library_dir())
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	pipeline := `{"__type_guid": "6b1f3c2e-7d4a-4e85-9c0b-2a5f8d1e4c73", "slots": [], "steps": [], "next_id": 1}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(pipeline)) == nil)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	doc := inspector.asset_doc_get(path)
	if !testing.expect(t, doc != nil, "the pipeline loads as a document") do return

	undo.push_asset_owner(doc.guid, doc.data.data, doc.data.id)
	defer undo.pop_owner()
	elem := type_info_of(engine.Pipeline_Slot)
	// The document's live array, fetched fresh for every step as the
	// inspector does each frame.
	slots :: proc(doc: ^inspector.Asset_Doc) -> ^runtime.Raw_Dynamic_Array {
		return (^runtime.Raw_Dynamic_Array)(&(^engine.Render_Pipeline)(doc.data.data).slots)
	}
	offset := offset_of(engine.Render_Pipeline, slots)

	inspector.array_add_element(slots(doc), offset, elem, nil)
	testing.expect_value(t, slots(doc).len, 1)
	testing.expect_value(t, len(s.items), 1)
	inspector.array_add_element(slots(doc), offset, elem, nil)
	inspector.array_remove_element(slots(doc), offset, elem, 0, nil)
	testing.expect_value(t, slots(doc).len, 1)
	testing.expect_value(t, len(s.items), 3)

	undo.apply_undo(s)
	testing.expect_value(t, slots(doc).len, 2)
	undo.apply_undo(s)
	testing.expect_value(t, slots(doc).len, 1)
	undo.apply_undo(s)
	testing.expect_value(t, slots(doc).len, 0)
}
