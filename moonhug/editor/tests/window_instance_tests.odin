package editor_tests

// Window instances (editor/window): a window opens once plainly and once per
// asset, opening the same asset again returns its instance, an asset
// instance's tab names that asset's document, closing an instance frees its
// state through the window's closed proc, and saved keys reopen the
// instances whose window and asset still exist.

import "core:encoding/uuid"
import "core:fmt"
import "core:testing"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import core "moonhug:libs/core"

@(private = "file") _ASSET_A :: "2b6f0d3e-91a4-4c27-8e5b-7d1c3a9f4e10"
@(private = "file") _ASSET_B :: "6e83a1c5-0f2d-4b98-a7c4-1d5e9b2f8a63"

@(private = "file")
_fixture: struct {
	registered: bool,
	closed:     int, // closed proc calls
}

@(private = "file")
_guid :: proc(s: string) -> core.Asset_GUID {
	g, _ := uuid.read(s)
	return core.Asset_GUID(g)
}

// A window with per-instance state, and a stand-in owner holding asset A's
// document. Registered once for the test process.
@(private = "file")
_fixture_register :: proc() {
	if _fixture.registered do return
	_fixture.registered = true
	wnd.register("instance_test", "Instance Test", "X", proc(w: ^wnd.Window) {}, 0, 0, closed = proc(w: ^wnd.Window) {
		_fixture.closed += 1
		free(w.data)
		w.data = nil
	})
	session.document_owner_add({
		name = "window_instance_test",
		list = proc(out: ^[dynamic]session.Document) {
			append(out, session.Document{guid = _guid(_ASSET_A), path = "assets/A.mat", can_discard = true})
		},
		save = proc(key: rawptr) -> bool {return true},
		discard = proc(key: rawptr) {},
	})
}

@(test)
test_window_instances_per_asset :: proc(t: ^testing.T) {
	_fixture_register()
	a, b := _guid(_ASSET_A), _guid(_ASSET_B)
	key_a := fmt.tprintf("instance_test/%s", _ASSET_A)
	key_b := fmt.tprintf("instance_test/%s", _ASSET_B)

	plain := wnd.open("instance_test")
	wa := wnd.open("instance_test", a)
	wb := wnd.open("instance_test", b)
	testing.expect(t, plain != nil && wa != nil && wb != nil, "every open returns its instance")
	if plain == nil || wa == nil || wb == nil do return
	testing.expect(t, wnd.open("instance_test", a) == wa, "opening the same asset again returns its instance")
	testing.expect_value(t, plain.key, "instance_test")
	testing.expect_value(t, wa.key, key_a)
	testing.expect(t, wa.asset == a && wb.asset == b, "each instance knows its asset")

	// The draw proc keeps its state in the instance.
	wa.data = new(int)
	wb.data = new(int)

	d, ok := session.view_document(key_a)
	testing.expect(t, ok && d.guid == a, "asset A's instance names A's document")
	_, none := session.view_document(key_b)
	testing.expect(t, !none, "asset B has no open document")

	keys := wnd.open_keys()
	testing.expect_value(t, len(keys), 3)

	before := _fixture.closed
	wnd.close(key_a)
	wnd.close(key_b)
	wnd.close("instance_test")
	wnd.draw_all() // removes closed instances, draws nothing
	testing.expect_value(t, _fixture.closed - before, 3)
	testing.expect(t, !wnd.is_open("instance_test"), "every instance is gone")
	_, still := session.view_document(key_a)
	testing.expect(t, !still, "a closed instance names no document")

	// A saved key reopens when its window exists. Asset A is not in the
	// asset database here, so its instance stays closed.
	wnd.open_saved({"instance_test", key_a, "no_such_window"})
	testing.expect(t, wnd.find("instance_test") != nil, "the plain instance reopens")
	testing.expect(t, wnd.find(key_a) == nil, "an instance whose asset is gone does not")
	wnd.close("instance_test")
	wnd.draw_all()
}
