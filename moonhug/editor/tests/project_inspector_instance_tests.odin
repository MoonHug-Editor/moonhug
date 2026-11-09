package editor_tests

// Project Inspector instances (inspector/window_project_inspector.odin): each
// instance has its own state and lock, and shows what session.window_asset
// names for it, as every window with a lock reads its target: the project
// selection, or its lock's asset while it is locked. A closed instance's
// state goes with it, and its lock waits while the instance can come back.

import "core:strings"
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
		session.window_lock_set(PI, false)
		editor.sel_proj_clear()
		wnd.close(second.key)
		wnd.close(PI)
		wnd.draw_all()
	}

	first_data := inspector.project_inspector_data(PI)
	second_data := inspector.project_inspector_data(second.key)
	testing.expect(t, first_data != nil && second_data != nil && first_data != second_data, "each instance has its own state")

	editor.sel_proj_only(A)
	testing.expect_value(t, session.window_asset(PI).path, A)
	testing.expect_value(t, session.window_asset(second.key).path, A)

	session.window_lock_set(second.key, true)
	editor.sel_proj_only(B)
	testing.expect_value(t, session.window_asset(PI).path, B)
	testing.expect_value(t, session.window_asset(second.key).path, A)

	// Unlocked, it shows the selection again.
	session.window_lock_set(second.key, false)
	testing.expect_value(t, session.window_asset(second.key).path, B)

	key := second.key
	wnd.close(key)
	testing.expect(t, inspector.project_inspector_data(key) == nil, "a closed instance has no state")
}

// A locked copy closed and brought back with Reopen Closed is locked to what
// it held. A copy opened fresh under the same key starts unlocked. draw_all is
// called only while no instance is open: it would draw them.
@(test)
test_project_inspector_lock_comes_back_with_its_window :: proc(t: ^testing.T) {
	PI :: inspector.PROJECT_INSPECTOR
	A :: "moonhug/tests"
	B :: "moonhug/editor"
	if !wnd.is_registered(PI) {
		wnd.register(PI, PI, "X", inspector.project_inspector_window_draw, 0, 0, closed = inspector.project_inspector_window_closed, lock = .Instance)
	}
	second := wnd.open_another(PI)
	testing.expect(t, second != nil, "another instance opens")
	if second == nil do return
	key := strings.clone(second.key, context.temp_allocator)
	defer {
		session.window_lock_set(key, false)
		editor.sel_proj_clear()
		wnd.close(key)
		wnd.draw_all()
	}

	editor.sel_proj_only(A)
	session.window_lock_set(key, true)
	editor.sel_proj_only(B)

	// Closed: the lock waits, still holding A.
	wnd.close(key)
	wnd.draw_all()
	editor.window_locks_prune()
	testing.expect(t, wnd.find(key) == nil, "the copy closed")
	testing.expect(t, session.window_locked(key), "the lock waits for its window")

	// Reopen Closed: the same key, locked to A again.
	back := wnd.reopen_closed()
	testing.expect(t, back != nil && back.key == key && back.reopened, "Reopen Closed brings the copy back")
	editor.window_locks_prune()
	testing.expect(t, session.window_locked(key), "the reopened copy is locked")
	testing.expect_value(t, session.window_asset(key).path, A)

	// Closed again, then a copy opened fresh takes the free key: unlocked.
	wnd.close(key)
	wnd.draw_all()
	editor.window_locks_prune()
	fresh := wnd.open_another(PI)
	testing.expect(t, fresh != nil && fresh.key == key && !fresh.reopened, "a fresh copy takes the key")
	editor.window_locks_prune()
	testing.expect(t, !session.window_locked(key), "a fresh copy starts unlocked")
	testing.expect_value(t, session.window_asset(key).path, B)
}

// A lock waiting for its window outlives a restart only when a host keeps the
// window (a workspace frame lists it): the closed list does not.
@(test)
test_waiting_window_lock_survives_a_restart_only_in_a_host :: proc(t: ^testing.T) {
	PI :: inspector.PROJECT_INSPECTOR
	KEY :: PI + "/7"
	if !wnd.is_registered(PI) {
		wnd.register(PI, PI, "X", inspector.project_inspector_window_draw, 0, 0, closed = inspector.project_inspector_window_closed, lock = .Instance)
	}
	prev_hook := wnd.kept_keys_hook
	defer wnd.kept_keys_hook = prev_hook
	wnd.kept_keys_hook = nil
	wnd.open_saved({KEY})
	testing.expect(t, wnd.find(KEY) != nil, "the copy opens from its key")
	defer {
		session.window_lock_set(KEY, false)
		editor.sel_proj_clear()
		wnd.close(KEY)
		wnd.draw_all()
	}
	editor.sel_proj_only("moonhug/tests")
	session.window_lock_set(KEY, true)
	wnd.close(KEY)
	wnd.draw_all()
	editor.window_locks_prune()
	testing.expect(t, session.window_locked(KEY), "the lock waits while Reopen Closed can bring the copy back")
	testing.expect(t, !_held(KEY), "a lock only the closed list keeps is not saved")

	wnd.kept_keys_hook = proc(out: ^[dynamic]string) { append(out, KEY) }
	testing.expect(t, _held(KEY), "a lock a host keeps is saved")
}

@(private = "file")
_held :: proc(key: string) -> bool {
	for l in editor.window_locks_held() do if l.key == key do return true
	return false
}
