package editor_tests

// Project Inspector instances (inspector/project_inspector_window.odin): each
// instance has its own state and lock, and shows what session.view_asset
// names for it, as every view with a lock reads its target: the project
// selection, or its lock's asset while it is locked. A closed instance's
// state goes with it.

import "core:testing"
import "moonhug:editor"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"

@(test)
test_project_inspector_instances_show_the_selection_or_their_lock :: proc(t: ^testing.T) {
	PI :: inspector.PROJECT_INSPECTOR
	A :: "moonhug/tests"
	B :: "moonhug/editor"
	if !wnd.is_registered(PI) {
		wnd.register(PI, PI, "X", inspector.project_inspector_window_draw, 0, 0, closed = inspector.project_inspector_window_closed, lock = .Instance)
	}
	wnd.open(PI)
	second := wnd.open_another(PI)
	testing.expect(t, second != nil, "another instance opens")
	if second == nil do return
	defer {
		session.view_lock_set(PI, false)
		editor.sel_proj_clear()
		wnd.close(second.key)
		wnd.close(PI)
		wnd.draw_all()
	}

	first_data := inspector.project_inspector_data(PI)
	second_data := inspector.project_inspector_data(second.key)
	testing.expect(t, first_data != nil && second_data != nil && first_data != second_data, "each instance has its own state")

	editor.sel_proj_only(A)
	testing.expect_value(t, session.view_asset(PI).path, A)
	testing.expect_value(t, session.view_asset(second.key).path, A)

	session.view_lock_set(second.key, true)
	editor.sel_proj_only(B)
	testing.expect_value(t, session.view_asset(PI).path, B)
	testing.expect_value(t, session.view_asset(second.key).path, A)

	// Unlocked, it shows the selection again.
	session.view_lock_set(second.key, false)
	testing.expect_value(t, session.view_asset(second.key).path, B)

	key := second.key
	wnd.close(key)
	testing.expect(t, inspector.project_inspector_data(key) == nil, "a closed instance has no state")
}
