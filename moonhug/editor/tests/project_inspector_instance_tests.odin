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
import "moonhug:editor/workspace"

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
// it held. A copy opened fresh never takes its key, and the plain instance
// opened fresh from the menu starts unlocked. draw_all is called only while
// no instance is open: it would draw them.
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
	fresh_key: string
	defer {
		session.window_lock_set(key, false)
		session.window_lock_set(PI, false)
		editor.sel_proj_clear()
		wnd.close(key)
		wnd.close(fresh_key)
		wnd.close(PI)
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

	// Closed again, then a copy opened fresh: another key, unlocked, and the
	// lock still waits for its own copy.
	wnd.close(key)
	wnd.draw_all()
	editor.window_locks_prune()
	fresh := wnd.open_another(PI)
	testing.expect(t, fresh != nil && fresh.key != key && !fresh.reopened, "a fresh copy takes another key")
	if fresh == nil do return
	fresh_key = strings.clone(fresh.key, context.temp_allocator)
	editor.window_locks_prune()
	testing.expect(t, !session.window_locked(fresh_key), "a fresh copy starts unlocked")
	testing.expect_value(t, session.window_asset(fresh_key).path, B)
	testing.expect(t, session.window_locked(key), "the closed copy's lock still waits")

	// The plain instance's key is reused by design: opened fresh from the
	// menu after it closed locked, it starts unlocked.
	plain := wnd.open(PI)
	editor.sel_proj_only(A)
	session.window_lock_set(PI, true)
	wnd.close(PI)
	wnd.close(fresh_key)
	wnd.draw_all()
	editor.window_locks_prune()
	testing.expect(t, plain != nil && session.window_locked(PI), "the closed plain instance's lock waits")
	again := wnd.open(PI)
	editor.window_locks_prune()
	testing.expect(t, again != nil && !again.reopened, "the menu opens it fresh")
	testing.expect(t, !session.window_locked(PI), "the plain instance opened fresh starts unlocked")
}

// The lock of a window in a workspace frame is saved in its workspace, not in
// the user settings, and a window the workspace opens again takes it: after a
// restart, in another project, when the workspace's source brings it back.
@(test)
test_frame_window_lock_travels_with_its_workspace :: proc(t: ^testing.T) {
	PI :: inspector.PROJECT_INSPECTOR
	KEY :: PI + "/7"
	A :: "moonhug/tests"
	if !wnd.is_registered(PI) {
		wnd.register(PI, PI, "X", inspector.project_inspector_window_draw, 0, 0, closed = inspector.project_inspector_window_closed, lock = .Instance)
	}
	ws := workspace.make_workspace("Lock Test")
	defer workspace.workspace_free(ws)
	workspace.frame_add(ws, KEY, {0, 0, 300, 200})
	prev_hook := wnd.kept_keys_hook
	defer wnd.kept_keys_hook = prev_hook
	wnd.kept_keys_hook = proc(out: ^[dynamic]string) { append(out, KEY) }
	defer {
		session.window_lock_set(KEY, false)
		editor.sel_proj_clear()
		wnd.close(KEY)
		wnd.draw_all()
	}

	wnd.open_saved({KEY})
	editor.sel_proj_only(A)
	session.window_lock_set(KEY, true)
	testing.expect(t, editor.workspace_locks_sync(ws), "locking the window changes its workspace")
	testing.expect_value(t, len(ws.windows), 1)
	testing.expect(t, !editor.workspace_locks_sync(ws), "nothing changed, nothing to save")
	testing.expect(t, !_held(KEY), "the user settings leave a frame window's lock to its workspace")

	// The window and its lock are gone, as after a restart or in a session
	// that never had them: the workspace still holds the lock, and the
	// window it opens again takes it.
	wnd.close(KEY)
	wnd.draw_all()
	session.window_lock_set(KEY, false)
	testing.expect(t, !editor.workspace_locks_sync(ws), "a window that is not open keeps what is saved for it")
	testing.expect_value(t, len(ws.windows), 1)
	wnd.open_saved({KEY})
	editor.sel_proj_only("moonhug/editor")
	editor.workspace_lock_take(ws, KEY)
	testing.expect(t, session.window_locked(KEY), "the window takes its workspace's lock")
	testing.expect_value(t, session.window_asset(KEY).path, A)

	// Unlocked while open: the workspace forgets the lock.
	session.window_lock_set(KEY, false)
	testing.expect(t, editor.workspace_locks_sync(ws) && len(ws.windows) == 0, "unlocking reaches the workspace")

	// A lock goes with its window's tab.
	session.window_lock_set(KEY, true)
	editor.workspace_locks_sync(ws)
	workspace.tab_remove(ws, 0, 0)
	testing.expect(t, editor.workspace_locks_sync(ws) && len(ws.windows) == 0, "a window out of every frame leaves no lock behind")
}

@(private = "file")
_held :: proc(key: string) -> bool {
	for l in editor.window_locks_held() do if l.key == key do return true
	return false
}
