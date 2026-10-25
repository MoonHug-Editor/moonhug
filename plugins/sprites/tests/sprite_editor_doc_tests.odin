package sprites_tests

// The Sprite Editor edits a working copy of the texture's import settings
// (inspector.asset_doc_copy_open): the .meta and the shared import settings
// see nothing until Apply, undo steps through the copy's edits on the one
// undo queue, Discard drops them, and closing the window asks first. What it
// allocates in the copy (a slice and its name) is on the document allocator,
// which frees a value undo replaces.

import "core:mem"
import "core:os"
import "core:testing"
import "moonhug:editor"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import asset_pipeline "moonhug:editor/assets"
import assets "moonhug:libs/assets"
import "moonhug:packages/engine"
import sprites_editor "moonhug:packages/sprites/editor"
import common "moonhug:tests/common"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_sprite_editor_doc_tmp"
@(private = "file")
_PNG :: _DIR + "/Circle.png"

// A registered texture in a temp folder, undo's asset hook, and the Sprite
// Editor window declared. Returns the texture's guid.
@(private = "file")
_fixture :: proc(t: ^testing.T) -> (engine.Asset_GUID, bool) {
	os.make_directory(_DIR)
	bytes, rerr := os.read_entire_file("plugins/mhgui/assets/white.png", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the source png")
	if rerr != nil do return {}, false
	testing.expect(t, os.write_entire_file(_PNG, bytes) == nil)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	if !wnd.is_registered(sprites_editor.SPRITE_EDITOR) {
		wnd.register(sprites_editor.SPRITE_EDITOR, "Sprite Editor", "X", sprites_editor.sprite_editor_window_draw, 0, 0, closed = sprites_editor.sprite_editor_window_closed)
	}
	guid, ok := engine.asset_db_get_guid(_PNG)
	testing.expect(t, ok, "the png is an asset")
	return engine.Asset_GUID(guid), ok
}

// The Sprite Editor's working copy, re-read each time: undo and Apply replace
// its value.
@(private = "file")
_copy :: proc() -> ^inspector.Asset_Doc_Copy {
	d, ok := session.view_document(sprites_editor.SPRITE_EDITOR)
	if !ok do return nil
	return (^inspector.Asset_Doc_Copy)(d.key)
}

@(private = "file")
_slices :: proc(data: any) -> int {
	return len((^engine.TextureSettings)(data.data).sprites)
}

@(test)
test_sprite_editor_edits_reach_the_meta_only_on_apply :: proc(t: ^testing.T) {
	defer {
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	guid, ok := _fixture(t)
	if !ok do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()
	defer {
		wnd.close(sprites_editor.SPRITE_EDITOR)
		wnd.draw_all()
	}

	sprites_editor.sprite_editor_open(_PNG, guid)
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.asset_doc_copies_track(true)
	c := _copy()
	testing.expect(t, c != nil && _slices(c.data) == 1 && c.dirty, "the copy holds the new slice, unapplied")
	shared := inspector.import_settings_doc_get(_PNG)
	testing.expect(t, _slices(shared.data) == 0, "the shared import settings see nothing yet")
	d, has := session.view_document(sprites_editor.SPRITE_EDITOR)
	testing.expect(t, has && d.dirty, "the Sprite Editor's tab names its unapplied copy")

	// Undo and redo step through the copy, on the one queue.
	testing.expect_value(t, len(s.items), 1)
	undo.apply_undo(s)
	testing.expect(t, _slices(_copy().data) == 0 && !_copy().dirty, "undo takes the slice back")
	undo.apply_redo(s)
	testing.expect_value(t, _slices(_copy().data), 1)

	// Apply writes the .meta, and the shared import settings follow.
	testing.expect(t, inspector.asset_doc_copy_apply(_copy().id), "the copy applies")
	testing.expect(t, !_copy().dirty, "the copy matches the .meta")
	testing.expect_value(t, _slices(inspector.import_settings_doc_get(_PNG).data), 1)
	on_disk, read := assets.asset_pipeline_get_settings(_PNG, context.temp_allocator)
	testing.expect(t, read && _slices(on_disk) == 1, "the .meta has the slice")

	// Discard drops the copy's edits and its steps, and the handle stays.
	sprites_editor.sprite_editor_open(_PNG, guid) // the window resolves its copy each frame
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.asset_doc_copies_track(true)
	testing.expect(t, _slices(_copy().data) == 2 && _copy().dirty, "a second slice, unapplied")
	inspector.asset_doc_copy_discard(_copy().id)
	testing.expect_value(t, len(s.items), 0)
	testing.expect(t, _slices(_copy().data) == 1 && !_copy().dirty, "the copy is the .meta again")
}

// Closing the window with unapplied edits keeps it open and asks: Apply
// writes them and closes, Cancel keeps both.
@(test)
test_sprite_editor_asks_before_closing_with_unapplied_edits :: proc(t: ^testing.T) {
	defer {
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	guid, ok := _fixture(t)
	if !ok do return
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()
	defer widgets.dialog_close()

	sprites_editor.sprite_editor_open(_PNG, guid)
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.asset_doc_copies_track(true)

	// The registry asks the guard before a closed window goes, and keeps it
	// open on true. Called directly here: a window kept open would draw, and
	// a test has no imgui frame.
	w := wnd.find(sprites_editor.SPRITE_EDITOR)
	testing.expect(t, w != nil, "the window is open")
	if w == nil do return

	// Cancel: the window and its edits stay.
	testing.expect(t, editor.view_close_guard(w), "a close with unapplied edits is held")
	testing.expect(t, widgets.dialog_is_open(), "it asks")
	widgets.dialog_choose(2) // Cancel
	testing.expect(t, wnd.find(sprites_editor.SPRITE_EDITOR) != nil, "the window stays")
	testing.expect(t, _copy() != nil && _copy().dirty, "the edits are still there")

	// Apply: the edits reach the .meta and the window closes.
	testing.expect(t, editor.view_close_guard(w), "asked again")
	widgets.dialog_choose(0) // Apply
	testing.expect(t, editor.view_close_guard(w) == false, "nothing unapplied holds it now")
	wnd.draw_all() // the closed window goes, and its copy with it
	testing.expect(t, wnd.find(sprites_editor.SPRITE_EDITOR) == nil, "the window closed")
	testing.expect(t, _copy() == nil, "the copy closed with it")
	on_disk, read := assets.asset_pipeline_get_settings(_PNG, context.temp_allocator)
	testing.expect(t, read && _slices(on_disk) == 1, "the .meta has the slice")
}

// Two slices created and undone, as in the editor: each undo rebuilds the
// copy's value and frees the one it replaces.
@(test)
test_sprite_editor_slice_undo_frees_on_the_document_allocator :: proc(t: ^testing.T) {
	defer {
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	guid, ok := _fixture(t)
	if !ok do return
	defer engine.asset_db_shutdown()

	// The documents on a tracking allocator, as in a debug build. A free of
	// memory it did not hand out is recorded instead of panicking.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&track)
	prev := inspector.doc_allocator
	inspector.doc_allocator = mem.tracking_allocator(&track)
	defer inspector.doc_allocator = prev
	defer {
		wnd.close(sprites_editor.SPRITE_EDITOR)
		wnd.draw_all()
	}

	sprites_editor.sprite_editor_open(_PNG, guid)
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.asset_doc_copies_track(true)
	inspector.asset_doc_copy(_copy().id) // shown this frame, so the tracker compares it
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.asset_doc_copies_track(true)
	testing.expect_value(t, len(s.items), 2)

	undo.apply_undo(s)
	undo.apply_undo(s)
	inspector.asset_docs_shutdown() // frees every copy and every replaced value
	testing.expect_value(t, len(track.bad_free_array), 0)
}
