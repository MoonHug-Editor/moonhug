package editor_tests

// Saved window state (editor/window/window_saved.odin): a state asked for
// with `saved` comes back from its key's record without the `json:"-"`
// fields, a reopened instance has its whole struct back, a record goes with
// an instance that cannot come back while the plain instance's stays, and a
// workspace holds the state of its frames' windows.

import "core:fmt"
import "core:strings"
import "core:testing"
import editor "moonhug:editor"
import wnd "moonhug:editor/window"
import "moonhug:editor/workspace"

@(private = "file")
_Saved_State :: struct {
	ratio:  f32,
	count:  int,
	on:     bool,
	cursor: int `json:"-"`,
}

@(private = "file")
_INIT :: _Saved_State{ratio = 0.5, count = 3}

@(private = "file")
_register :: proc(id: string) {
	if !wnd.is_registered(id) do wnd.register(id, id, "X", proc(w: ^wnd.Window) {}, 0, 0)
}

// Closes `keys`, which takes them out of the registry.
@(private = "file")
_close :: proc(keys: ..string) {
	for k in keys do wnd.close(k)
	wnd.draw_all()
}

@(test)
test_window_saved_state_comes_back_from_its_record :: proc(t: ^testing.T) {
	ID :: "saved_test_record"
	_register(ID)
	defer _close(ID)

	// As after a restart: the settings gave the key a record.
	wnd.saved_set(ID, `{"ratio":0.25,"on":true,"cursor":9}`)
	w := wnd.open(ID)
	s := wnd.state(w, _INIT, saved = true)
	testing.expect_value(t, s.ratio, f32(0.25))
	testing.expect_value(t, s.on, true)
	testing.expect_value(t, s.count, 3) // not in the record: the init value
	testing.expect_value(t, s.cursor, 0) // never read

	// The record follows the open instance, keys sorted, without the
	// unsaved field.
	s.count = 7
	s.cursor = 4
	testing.expect_value(t, wnd.saved_text(ID), `{"count":7,"on":true,"ratio":0.25}`)
	testing.expect(t, wnd.saved_text(ID) == wnd.saved_text(ID), "an unchanged state gives the same text")
}

@(test)
test_window_saved_state_reopens_whole :: proc(t: ^testing.T) {
	ID :: "saved_test_reopen"
	_register(ID)
	defer _close(ID)

	s := wnd.state(wnd.open(ID), _INIT, saved = true)
	s.ratio = 0.75
	s.cursor = 11
	_close(ID)
	testing.expect_value(t, wnd.saved_text(ID), `{"count":3,"on":false,"ratio":0.75}`)

	// Reopen Closed: the struct itself, the unsaved field too.
	w := wnd.reopen_closed()
	if !testing.expect(t, w != nil && w.key == ID, "the instance reopens") do return
	r := wnd.state(w, _INIT, saved = true)
	testing.expect(t, r == s, "the reopened instance has its struct back")
	testing.expect_value(t, r.cursor, 11)
}

@(test)
test_window_saved_record_goes_with_its_instance :: proc(t: ^testing.T) {
	ID :: "saved_test_prune"
	COPY :: ID + "/5000"
	_register(ID)

	wnd.open_saved({ID, COPY})
	wnd.state(wnd.find(ID), _INIT, saved = true)
	wnd.state(wnd.find(COPY), _INIT, saved = true)
	_close(ID, COPY)
	testing.expect(t, wnd.saved_has(COPY), "a closed copy keeps its record while Reopen Closed remembers it")

	// Enough closed instances to push both out of the closed list.
	for i in 0 ..< 20 {
		key := fmt.tprintf("%s/%d", ID, 6000 + i)
		wnd.open_saved({key})
		_close(key)
	}
	testing.expect(t, !wnd.saved_has(COPY), "a copy that cannot come back leaves no record")
	testing.expect(t, wnd.saved_has(ID), "the plain instance's record stays for the next time it opens")

	// Opened again: as it was left.
	s := wnd.state(wnd.open(ID), _INIT, saved = true)
	s.count = 42
	_close(ID)
	r := wnd.state(wnd.open(ID), _INIT, saved = true)
	testing.expect_value(t, r.count, 42)
	_close(ID)
}

@(test)
test_frame_window_state_travels_with_its_workspace :: proc(t: ^testing.T) {
	ID :: "saved_test_frame"
	KEY :: ID + "/7000"
	KEY2 :: ID + "/7001"
	_register(ID)
	ws := workspace.make_workspace("State Test")
	defer workspace.workspace_free(ws)
	workspace.frame_add(ws, KEY, {0, 0, 300, 200})
	prev_hook := wnd.kept_keys_hook
	defer wnd.kept_keys_hook = prev_hook
	wnd.kept_keys_hook = proc(out: ^[dynamic]string) { append(out, KEY) }
	// Both at once: draw_all draws what is still open, and a test has no imgui.
	defer _close(KEY, KEY2)

	wnd.open_saved({KEY})
	s := wnd.state(wnd.find(KEY), _INIT, saved = true)
	s.ratio = 0.125
	testing.expect(t, editor.workspace_states_sync(ws), "the window's state reaches its workspace")
	testing.expect(t, !editor.workspace_states_sync(ws), "nothing changed, nothing to save")
	testing.expect_value(t, workspace.state_text(ws, KEY), `{"count":3,"on":false,"ratio":0.125}`)
	saved := strings.clone(workspace.state_text(ws, KEY), context.temp_allocator)

	// A lock and a state share the window's record, and each goes alone.
	testing.expect(t, workspace.lock_set(ws, KEY, {{scene = "s", local_id = 1}}, nil))
	testing.expect_value(t, len(ws.windows), 1)
	testing.expect(t, workspace.lock_set(ws, KEY, nil, nil))
	testing.expect_value(t, workspace.state_text(ws, KEY), saved)

	// Another session: the registry knows nothing of the key, and the
	// workspace gives the window its state before it opens.
	other := workspace.make_workspace("State Test 2")
	defer workspace.workspace_free(other)
	workspace.frame_add(other, KEY2, {0, 0, 300, 200})
	testing.expect(t, workspace.state_set(other, KEY2, saved))
	editor.workspace_state_give(other, KEY2)
	wnd.open_saved({KEY2})
	r := wnd.state(wnd.find(KEY2), _INIT, saved = true)
	testing.expect_value(t, r.ratio, f32(0.125))

	// A state goes with its window's tab.
	workspace.tab_remove(ws, 0, 0)
	testing.expect(t, editor.workspace_locks_sync(ws) && len(ws.windows) == 0, "a window out of every frame leaves no record behind")
}
