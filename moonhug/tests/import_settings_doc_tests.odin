package tests

// Import settings documents (editor/inspector/import_settings_docs.odin): one
// document per asset, shared by the import settings inspector and the Sprite
// Editor, recorded for undo by a per-frame compare, committed by Apply.

import "core:os"
import "core:strings"
import "core:testing"
import "../editor/inspector"
import "../editor/undo"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_import_settings_doc_tmp"
@(private = "file")
_PNG :: _DIR + "/Tile.png"

// A registered texture in a temp folder, with undo's asset hooks installed.
@(private = "file")
_texture_fixture :: proc(t: ^testing.T) -> bool {
	os.make_directory(_DIR)
	bytes, rerr := os.read_entire_file("plugins/mhgui/assets/white.png", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the source png")
	if rerr != nil do return false
	testing.expect(t, os.write_entire_file(_PNG, bytes) == nil)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	return true
}

// The document's data, re-read each time: undo swaps the instance.
@(private = "file")
_ts :: proc(doc: ^inspector.Asset_Doc) -> ^engine.TextureSettings {
	return cast(^engine.TextureSettings)doc.data.data
}

@(test)
test_import_settings_edits_undo_and_track_dirty :: proc(t: ^testing.T) {
	defer {
		_remove_tree(_DIR)
		_remove_tree("library")
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	if !_texture_fixture(t) do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	doc := inspector.import_settings_doc_get(_PNG)
	testing.expect(t, doc != nil && doc.data.id == typeid_of(engine.TextureSettings), "the png has a texture settings document")
	if doc == nil do return
	testing.expect(t, !doc.dirty, "a fresh document equals the .meta")
	ppu := _ts(doc).pixels_per_unit

	// A finished edit is one step.
	_ts(doc).pixels_per_unit = 32
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 1)
	testing.expect(t, doc.dirty, "differs from the .meta")

	// Frames where no edit can have finished (a widget still held) compare
	// nothing, and the release frame records the whole gesture once.
	inspector.import_settings_doc_get(_PNG) // shown this frame
	_ts(doc).pixels_per_unit = 40
	inspector.import_settings_track(false)
	_ts(doc).pixels_per_unit = 64
	inspector.import_settings_track(false)
	testing.expect_value(t, len(s.items), 1)
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 2)

	// A frame with no change records nothing.
	inspector.import_settings_doc_get(_PNG)
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 2)

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, _ts(doc).pixels_per_unit, f32(32))
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 2) // the restore is not a new step
	testing.expect(t, undo.apply_undo(s), "undo to the .meta state")
	testing.expect_value(t, _ts(doc).pixels_per_unit, ppu)
	testing.expect(t, !doc.dirty, "back to the .meta: clean")
	testing.expect(t, undo.apply_redo(s) && undo.apply_redo(s), "redo both")
	testing.expect_value(t, _ts(doc).pixels_per_unit, f32(64))
	testing.expect(t, doc.dirty, "dirty again")

	// File/Save leaves import settings alone: they commit through Apply, and a
	// save would write them over the png itself.
	png_before, _ := os.read_entire_file(_PNG, context.temp_allocator)
	saved, failed := inspector.asset_docs_save_dirty()
	png_after, _ := os.read_entire_file(_PNG, context.temp_allocator)
	testing.expect(t, saved == 0 && failed == 0 && string(png_before) == string(png_after), "File/Save does not touch import settings")
	testing.expect(t, doc.dirty, "still unapplied")

	// Apply writes the .meta and leaves the document clean.
	testing.expect(t, inspector.import_settings_apply(doc), "Apply")
	testing.expect(t, !doc.dirty, "clean after Apply")
	settings, ok := engine.asset_pipeline_get_settings(_PNG, context.temp_allocator)
	on_disk, is_tex := settings.(engine.TextureSettings)
	testing.expect(t, ok && is_tex && on_disk.pixels_per_unit == 64, "the .meta carries the applied value")

	// Revert is one step back to the .meta, and undo brings the edit back.
	inspector.import_settings_doc_get(_PNG)
	_ts(doc).sprite_border = {1, 2, 3, 4}
	inspector.import_settings_track(true)
	steps := len(s.items)
	inspector.import_settings_revert(doc)
	testing.expect_value(t, len(s.items), steps + 1)
	testing.expect(t, _ts(doc).sprite_border == {} && !doc.dirty, "Revert reloads the .meta")
	testing.expect(t, undo.apply_undo(s), "undo the Revert")
	testing.expect(t, _ts(doc).sprite_border == {1, 2, 3, 4} && doc.dirty, "the edit is back")
}

// The inspector and the Sprite Editor edit one document, so an edit in one
// shows in the other and nothing has to reload the other's copy.
@(test)
test_import_settings_document_is_shared :: proc(t: ^testing.T) {
	defer {
		_remove_tree(_DIR)
		_remove_tree("library")
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	if !_texture_fixture(t) do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()
	defer inspector.unload()

	inspector.load_import_settings(_PNG)
	doc := inspector.import_settings_doc_get(_PNG)
	testing.expect(t, doc != nil && inspector.inspectorData.settingsDoc == doc, "the inspector shows the shared document")
}

// Deleting the asset drops its settings document and the undo steps that edit
// it, like an asset document.
@(test)
test_deleting_an_asset_drops_its_import_settings_document :: proc(t: ^testing.T) {
	defer {
		_remove_tree(_DIR)
		_remove_tree("library")
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	if !_texture_fixture(t) do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	doc := inspector.import_settings_doc_get(_PNG)
	if doc == nil do return
	guid := doc.guid
	_ts(doc).pixels_per_unit = 16
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 1)

	os.remove(_PNG)
	os.remove(strings.concatenate({_PNG, ".meta"}, context.temp_allocator))
	asset_pipeline.asset_db_refresh()
	testing.expect_value(t, len(s.items), 0)
	testing.expect(t, inspector.asset_doc_payload_ptr(guid, .Import_Settings) == nil, "the document is gone")
}

// A reimport can rewrite the .meta (the model importer adds new clips). A clean
// document reloads so the next Apply does not write the old version back. One
// with unapplied edits keeps them.
@(test)
test_reimport_reloads_a_clean_import_settings_document :: proc(t: ^testing.T) {
	defer {
		_remove_tree(_DIR)
		_remove_tree("library")
	}
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	if !_texture_fixture(t) do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	doc := inspector.import_settings_doc_get(_PNG)
	if doc == nil do return

	// The .meta changes behind the document's back, then the asset reimports.
	settings, ok := engine.asset_pipeline_get_settings(_PNG, context.temp_allocator)
	if !ok do return
	(cast(^engine.TextureSettings)settings.data).pixels_per_unit = 8
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(_PNG, settings))
	asset_pipeline.asset_pipeline_reimport(_PNG)
	testing.expect_value(t, _ts(doc).pixels_per_unit, f32(8))
	testing.expect(t, !doc.dirty, "reloaded and clean")

	// With an unapplied edit the document keeps it.
	_ts(doc).pixels_per_unit = 12
	inspector.import_settings_track(true)
	asset_pipeline.asset_pipeline_reimport(_PNG)
	testing.expect_value(t, _ts(doc).pixels_per_unit, f32(12))
}
