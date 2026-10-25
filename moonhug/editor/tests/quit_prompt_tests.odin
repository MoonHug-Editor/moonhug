package editor_tests

// The quit prompt (editor/quit_prompt.odin): a quit with unsaved files is
// held and asks first. Cancel keeps the editor running, Save All writes the
// files and lets the quit through. The unsaved file comes from a stand-in
// document owner, so the test needs no project.

import "core:strings"
import "core:testing"
import "moonhug:editor"
import "moonhug:editor/menu"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import gfx "moonhug:libs/gfx"

@(private = "file")
_stand_in: struct {
	registered: bool,
	dirty:      bool,
	saved:      int,
}

@(private = "file")
_stand_in_owner :: proc() {
	if _stand_in.registered do return
	_stand_in.registered = true
	session.document_owner_add({
		name = "quit_prompt_test",
		list = proc(out: ^[dynamic]session.Document) {
			append(out, session.Document{path = "assets/Unsaved.mat", dirty = _stand_in.dirty, can_discard = true})
		},
		save = proc(key: rawptr) -> bool {
			_stand_in.saved += 1
			_stand_in.dirty = false
			return true
		},
		discard = proc(key: rawptr) {_stand_in.dirty = false},
	})
}

@(test)
test_quit_with_unsaved_files_asks_first :: proc(t: ^testing.T) {
	_stand_in_owner()
	_stand_in.dirty = true
	defer _stand_in.dirty = false
	defer menu.quit_requested = false
	defer widgets.dialog_close()

	// The window's close button asks the same as File/Quit.
	gfx.request_quit()
	testing.expect(t, !editor.quit_gate(), "the quit is held")
	testing.expect(t, !gfx.quit_requested() && !menu.quit_requested, "and withdrawn while the prompt is open")
	d, open := widgets.dialog_current()
	testing.expect(t, open && len(d.buttons) == 3, "the prompt offers Save All, Don't Save and Cancel")
	testing.expect(t, strings.contains(d.description, "Unsaved.mat"), "it names the file")

	widgets.dialog_choose(2) // Cancel
	testing.expect(t, !editor.quit_gate(), "Cancel keeps the editor running")
	testing.expect_value(t, _stand_in.saved, 0)

	menu.quit_requested = true
	testing.expect(t, !editor.quit_gate(), "a second quit asks again")
	widgets.dialog_choose(0) // Save All
	testing.expect_value(t, _stand_in.saved, 1)
	testing.expect(t, editor.quit_gate(), "Save All lets the quit through")
}
