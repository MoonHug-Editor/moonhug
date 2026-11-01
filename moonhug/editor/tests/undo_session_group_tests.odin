package editor_tests

// An edit session's group (editor/undo/undo_session.odin). edit_session_end
// opens one group for the session and closes it again. begin_group_command
// opens nothing while the stack is applying or not recording, so a session
// that ends then must leave a caller's group open and untouched.

import "core:testing"
import "moonhug:editor/undo"

// Opens a caller's group holding one value record, begins a session on
// `field` while recording, edits it, applies `stop` to the stack and ends the
// session. Returns the caller's group depth and its sub count afterwards.
@(private = "file")
_session_under_outer_group :: proc(s: ^undo.Undo_Stack, field: ^int, stop: proc(s: ^undo.Undo_Stack)) -> (depth, subs: int) {
	outer: int
	undo.begin_group_command(s)
	old_json := undo.capture_json(&outer, int)
	outer = 1
	undo.push_value(s, undo.make_raw_target(&outer, 0, int), old_json, undo.capture_json(&outer, int))

	targets := []undo.Edit_Target{{kind = .Raw, raw_ptr = field, raw_tid = int, field_ptr = field, field_tid = int}}
	sess := undo.edit_session_begin(targets, "Field")
	field^ = 7
	stop(s)
	undo.edit_session_end(&sess)

	depth = len(s.txn_stack)
	if depth > 0 do subs = len(s.txn_stack[depth - 1].subs)
	return
}

@(test)
test_session_ending_while_applying_keeps_outer_group :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	prev_listener := undo.commit_listener
	undo.commit_listener = nil
	defer undo.commit_listener = prev_listener

	field: int
	depth, subs := _session_under_outer_group(s, &field, proc(s: ^undo.Undo_Stack) { s.applying = true })
	s.applying = false
	testing.expect_value(t, depth, 1)
	testing.expect_value(t, subs, 1)
	testing.expect_value(t, len(s.items), 0)

	undo.end_group_command(s)
	testing.expect_value(t, len(s.txn_stack), 0)
	testing.expect_value(t, len(s.items), 1)
}

@(test)
test_session_ending_while_not_recording_keeps_outer_group :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	prev_listener := undo.commit_listener
	undo.commit_listener = nil
	defer undo.commit_listener = prev_listener

	field: int
	depth, subs := _session_under_outer_group(s, &field, proc(s: ^undo.Undo_Stack) { s.recording = false })
	s.recording = true
	testing.expect_value(t, depth, 1)
	testing.expect_value(t, subs, 1)
	testing.expect_value(t, len(s.items), 0)

	undo.end_group_command(s)
	testing.expect_value(t, len(s.txn_stack), 0)
	testing.expect_value(t, len(s.items), 1)
}

// A session begun while the stack applies is inactive: it opens and closes
// nothing, and the caller's group keeps its record.
@(test)
test_session_begun_while_applying_keeps_outer_group :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	outer: int
	undo.begin_group_command(s)
	old_json := undo.capture_json(&outer, int)
	outer = 1
	undo.push_value(s, undo.make_raw_target(&outer, 0, int), old_json, undo.capture_json(&outer, int))

	field: int
	s.applying = true
	targets := []undo.Edit_Target{{kind = .Raw, raw_ptr = &field, raw_tid = int, field_ptr = &field, field_tid = int}}
	sess := undo.edit_session_begin(targets, "Field")
	field = 7
	undo.edit_session_end(&sess)
	s.applying = false

	testing.expect(t, !undo.edit_session_active(&sess))
	testing.expect_value(t, len(s.txn_stack), 1)
	testing.expect_value(t, len(s.txn_stack[0].subs), 1)
	undo.end_group_command(s)
	testing.expect_value(t, len(s.items), 1)
}
