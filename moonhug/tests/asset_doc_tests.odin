package tests

// Asset documents (editor/inspector/asset_docs.odin) live as long as their
// asset: deleting the asset drops its document and undo steps, and a save
// writes to where the asset is now. Before, a deleted material with unsaved
// edits came back on the next File/Save, without its .meta, as a new asset.

import "core:os"
import "core:testing"
import "../editor/inspector"
import "../editor/undo"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"

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
		_remove_tree("library")
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
		_remove_tree("library")
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
		_remove_tree("library")
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
