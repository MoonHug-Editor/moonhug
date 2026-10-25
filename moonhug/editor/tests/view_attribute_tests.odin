package editor_tests

// The procs behind view attributes receive the view they act for: a
// @(view_document) proc and a view menu action both see the instance's key
// and its view's id, so each instance of a window can answer for itself.

import "core:testing"
import "moonhug:editor/menu"
import "moonhug:editor/session"
import core "moonhug:libs/core"

@(private = "file")
_seen: struct {
	registered: bool,
	document:   session.View,
	action:     session.View,
	checked:    session.View,
}

@(test)
test_view_procs_receive_the_view :: proc(t: ^testing.T) {
	if !_seen.registered {
		_seen.registered = true
		session.view_document_add("probe", proc(view: session.View) -> core.Asset_GUID {
			_seen.document = view
			return {}
		})
	}
	_, found := session.view_document("probe/instance_1")
	testing.expect(t, !found, "the probe edits nothing")
	testing.expect_value(t, _seen.document.key, "probe/instance_1")
	testing.expect_value(t, _seen.document.id, "probe")

	tree := menu.tree_make()
	defer menu.tree_destroy(tree)
	menu.tree_add_view_item(tree, "Do", proc(view: session.View) {_seen.action = view}, checked = proc(view: session.View) -> bool {
		_seen.checked = view
		return true
	})
	ok, ticked := menu.tree_invoke(tree, "Do", session.view_of("probe/instance_2"))
	testing.expect(t, ok && ticked, "the action runs and reports its tick")
	testing.expect_value(t, _seen.action.key, "probe/instance_2")
	testing.expect_value(t, _seen.checked.id, "probe")
}
