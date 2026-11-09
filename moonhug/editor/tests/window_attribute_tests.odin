package editor_tests

// The procs behind window attributes receive the window they act for: a
// @(window_document) proc and a window menu action both see the instance's key
// and its window's id, so each instance of a window can answer for itself.

import "core:testing"
import "moonhug:editor/menu"
import "moonhug:editor/session"
import core "moonhug:libs/core"

@(private = "file")
_seen: struct {
	registered: bool,
	document:   session.Window_Ref,
	action:     session.Window_Ref,
	checked:    session.Window_Ref,
}

@(test)
test_window_procs_receive_the_window :: proc(t: ^testing.T) {
	if !_seen.registered {
		_seen.registered = true
		session.window_document_add("probe", proc(window: session.Window_Ref) -> core.Asset_GUID {
			_seen.document = window
			return {}
		})
	}
	_, found := session.window_document("probe/instance_1")
	testing.expect(t, !found, "the probe edits nothing")
	testing.expect_value(t, _seen.document.key, "probe/instance_1")
	testing.expect_value(t, _seen.document.id, "probe")

	tree := menu.tree_make()
	defer menu.tree_destroy(tree)
	menu.tree_add_window_item(tree, "Do", proc(window: session.Window_Ref) {_seen.action = window}, checked = proc(window: session.Window_Ref) -> bool {
		_seen.checked = window
		return true
	})
	ok, ticked := menu.tree_invoke(tree, "Do", session.window_ref_of("probe/instance_2"))
	testing.expect(t, ok && ticked, "the action runs and reports its tick")
	testing.expect_value(t, _seen.action.key, "probe/instance_2")
	testing.expect_value(t, _seen.checked.id, "probe")
}
