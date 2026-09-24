package tests

// The generic modal dialog (editor/widgets/dialog.odin) and its first user,
// the asset delete confirmation (editor/project_file_ops.odin). The draw path
// needs an imgui frame, so these tests drive the dialog through dialog_choose,
// the same entry the draw loop calls for a click or a key.

import "core:os"
import "core:strings"
import "core:testing"
import "../editor"
import "moonhug:editor/widgets"

// What the chaining action saw. File-level, the same way a real dialog keeps
// its state.
@(private = "file")
_chain_pressed: int
@(private = "file")
_chain_open_at_press: bool

// The dialog keeps its own copies: a caller passes temp strings and reuses
// its buffers right after dialog_open.
@(test)
test_dialog_copies_its_config :: proc(t: ^testing.T) {
	defer widgets.dialog_close()

	title := strings.clone("Title")
	label := strings.clone("OK")
	widgets.dialog_open({
		title       = title,
		description = "Body",
		buttons     = {{label = label, is_default = true}},
	})
	raw_data(title)[0] = 'X'
	raw_data(label)[0] = 'X'
	delete(title)
	delete(label)

	d, ok := widgets.dialog_current()
	testing.expect(t, ok, "the dialog is open")
	testing.expect_value(t, d.title, "Title")
	testing.expect_value(t, d.buttons[0].label, "OK")
}

// A press closes the dialog first, then runs the action, so an action can
// open the next dialog.
@(test)
test_dialog_press_closes_then_runs_the_action :: proc(t: ^testing.T) {
	defer widgets.dialog_close()

	_chain_pressed = 0
	_chain_open_at_press = false
	widgets.dialog_open({
		title   = "First",
		buttons = {
			{label = "A"},
			{label = "B", action = proc() {
				_chain_pressed += 1
				_chain_open_at_press = widgets.dialog_is_open()
				widgets.dialog_open({title = "Second", buttons = {{label = "OK"}}})
			}},
		},
	})
	widgets.dialog_choose(1)

	testing.expect_value(t, _chain_pressed, 1)
	testing.expect(t, !_chain_open_at_press, "the first dialog is closed when its action runs")
	d, ok := widgets.dialog_current()
	testing.expect(t, ok && d.title == "Second", "the action opened the next dialog")

	// A button without an action only closes.
	widgets.dialog_choose(0)
	testing.expect(t, !widgets.dialog_is_open(), "closed")
	testing.expect_value(t, _chain_pressed, 1)
}

// Delete asks first: the files stay until the user confirms, the dialog
// lists them, and Cancel drops the request. Confirming is not tested here, it
// would move the fixture to the real Trash.
@(test)
test_asset_delete_asks_before_trashing :: proc(t: ^testing.T) {
	dir :: "moonhug/tests/fixtures/_delete_confirm_tmp"
	path :: dir + "/Doomed.txt"
	os.make_directory(dir)
	defer _remove_tree(dir)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("x")) == nil)

	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	editor.sel_scene_clear()
	editor.sel_proj_clear()
	defer editor.sel_proj_clear()
	defer widgets.dialog_close()

	// A package root is never deleted, so it is not listed either.
	editor.sel_proj_only(path)
	editor.sel_proj_add("packages")
	editor.project_ops_delete()

	testing.expect(t, os.exists(path), "nothing is deleted before the answer")
	d, ok := widgets.dialog_current()
	testing.expect(t, ok, "the confirmation is open")
	if !ok do return
	testing.expect_value(t, d.title, "Delete selected asset?")
	testing.expect(t, strings.contains(d.description, path), "the dialog lists the file")
	pending := editor.project_ops_delete_pending()
	testing.expect(t, len(pending) == 1 && pending[0] == path, "only the file is pending, not the package root")
	testing.expect(t, len(d.buttons) == 2 && d.buttons[0].is_default && d.buttons[1].is_cancel, "Delete is the default, Cancel cancels")

	widgets.dialog_choose(1) // Cancel
	testing.expect(t, os.exists(path), "Cancel keeps the file")
	testing.expect(t, !widgets.dialog_is_open(), "Cancel closes the dialog")
	testing.expect_value(t, len(editor.project_ops_delete_pending()), 0)
	testing.expect_value(t, editor.sel_proj_count(), 2)
}

// Only protected paths selected: nothing to ask about, no dialog.
@(test)
test_asset_delete_of_a_package_root_opens_no_dialog :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	editor.sel_scene_clear()
	editor.sel_proj_clear()
	defer editor.sel_proj_clear()
	defer widgets.dialog_close()

	editor.sel_proj_only("packages")
	editor.project_ops_delete()
	testing.expect(t, !widgets.dialog_is_open(), "no dialog for a delete that would do nothing")
}
