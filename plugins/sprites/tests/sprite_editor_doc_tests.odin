package sprites_tests

// The Sprite Editor edits the texture's import settings document, so what it
// allocates there (a slice and its name) is on the document allocator: undo
// rebuilds the document and frees the replaced instance with that allocator.

import "core:mem"
import "core:os"
import "core:testing"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine"
import sprites_editor "moonhug:packages/sprites/editor"
import common "moonhug:tests/common"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_sprite_editor_doc_tmp"
@(private = "file")
_PNG :: _DIR + "/Circle.png"

// Two slices created and undone, as in the editor: each undo rebuilds the
// document and frees the instance it replaces.
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

	os.make_directory(_DIR)
	bytes, rerr := os.read_entire_file("plugins/mhgui/assets/white.png", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the source png")
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(_PNG, bytes) == nil)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	defer engine.asset_db_shutdown()
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)

	// The documents on a tracking allocator, as in a debug build. A free of
	// memory it did not hand out is recorded instead of panicking.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&track)
	prev := inspector.doc_allocator
	inspector.doc_allocator = mem.tracking_allocator(&track)
	defer inspector.doc_allocator = prev

	if !wnd.is_registered("sprite_editor") {
		wnd.register("sprite_editor", "Sprite Editor", "X", sprites_editor.sprite_editor_window_draw, 0, 0)
	}
	defer {
		wnd.close("sprite_editor")
		wnd.draw_all()
	}
	guid, ok := engine.asset_db_get_guid(_PNG)
	testing.expect(t, ok, "the png is an asset")
	sprites_editor.sprite_editor_open(_PNG, engine.Asset_GUID(guid))
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.import_settings_track(true)
	inspector.import_settings_doc_get(_PNG) // shown this frame, so the tracker compares it
	sprites_editor.sprite_editor_add_slice({0, 0, 1, 1})
	inspector.import_settings_track(true)
	testing.expect_value(t, len(s.items), 2)

	undo.apply_undo(s)
	undo.apply_undo(s)
	inspector.asset_docs_shutdown() // frees every document and every replaced instance
	testing.expect_value(t, len(track.bad_free_array), 0)
}
