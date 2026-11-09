package editor_tests

// Commands with arguments (docs/core/Keymaps.md): what keymap.command_add_args
// keeps, and how the settings panel runs a command again when its
// arguments change, replacing its last run instead of adding to the history.

import "core:testing"
import "moonhug:editor"
import "moonhug:editor/keymap"
import "moonhug:editor/undo"

@(private = "file")
_T_Args :: struct {
	n: int,
	v: [2]f32,
}

@(private = "file")
_T_ARGS_DEFAULT :: _T_Args{n = 2, v = {1, 0}}

// What the test command last ran with, and how often it ran.
@(private = "file")
_t_seen: _T_Args
@(private = "file")
_t_runs: int
// The value the test command writes through an undo step.
@(private = "file")
_t_value: int

@(private = "file")
_t_args_run :: proc(a: ^_T_Args) {
	_t_seen = a^
	_t_runs += 1
}

// Writes args.n into _t_value as one raw undo step, as a real command
// records its change.
@(private = "file")
_t_args_write :: proc(a: ^_T_Args) {
	_t_runs += 1
	s := undo.get()
	t := undo.make_raw_target(&_t_value, 0, int)
	old := undo.capture_json(&_t_value, int)
	_t_value = a.n
	undo.push_value(s, t, old, undo.capture_json(&_t_value, int), "Write")
}

@(test)
test_command_args_registration :: proc(t: ^testing.T) {
	prev := keymap.args_runner
	keymap.args_runner = nil
	defer keymap.args_runner = prev
	defer keymap.command_remove("t.args")

	c := keymap.command_add_args("T Args/Run", _t_args_run, _T_ARGS_DEFAULT, id = "t.args")
	testing.expect(t, c.args != nil && c.args_type == _T_Args)
	testing.expect_value(t, (^_T_Args)(c.args)^, _T_ARGS_DEFAULT)

	// Without a runner the command runs with its arguments directly.
	_t_runs = 0
	keymap.command_run(c)
	testing.expect_value(t, _t_runs, 1)
	testing.expect_value(t, _t_seen, _T_ARGS_DEFAULT)

	// JSON sets the fields it names, the rest keep their values.
	testing.expect(t, keymap.command_args_set_json(c, transmute([]u8)string(`{"n": 7}`)))
	testing.expect_value(t, (^_T_Args)(c.args)^, _T_Args{n = 7, v = {1, 0}})
	testing.expect(t, !keymap.command_args_set_json(c, transmute([]u8)string(`{"n": "x"}`)))
	testing.expect_value(t, string(keymap.command_args_json(c)), `{"n":7,"v":[1.00000000,0.00000000]}`)

	// Registered again with the same type, the last values stay. Reset puts
	// the declared defaults back.
	keymap.command_add_args("T Args/Run", _t_args_run, _T_Args{n = 9}, id = "t.args")
	testing.expect_value(t, (^_T_Args)(c.args).n, 7)
	keymap.command_args_reset(c)
	testing.expect_value(t, (^_T_Args)(c.args)^, _T_Args{n = 9})

	// Registered as a command without arguments, it has none.
	keymap.command_add("T Args/Run", proc() {}, id = "t.args")
	testing.expect(t, c.args == nil && c.run_args == nil && c.args_type == nil)
	testing.expect(t, keymap.command_args_json(c) == nil)
}

@(test)
test_command_args_adjust_last :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	defer editor.adjust_last_close()
	defer keymap.command_remove("t.adjust")

	c := keymap.command_add_args("T Args/Adjust", _t_args_write, _T_ARGS_DEFAULT, id = "t.adjust")
	_t_value, _t_runs = 0, 0

	// Run through the key's path: one undo step, the panel shows it.
	keymap.command_run(c)
	testing.expect_value(t, _t_value, 2)
	testing.expect_value(t, len(s.items), 1)
	testing.expect(t, editor.adjust_last_command() == c)
	testing.expect(t, editor.adjust_last_valid())

	// No edit, no run.
	testing.expect(t, !editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_runs, 1)

	// An edit undoes the last run and runs again: still one step.
	(^_T_Args)(c.args).n = 5
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_value, 5)
	testing.expect_value(t, len(s.items), 1)
	testing.expect_value(t, s.top, 1)
	testing.expect_value(t, _t_runs, 2)

	// Reset puts the defaults back, a change like any other: the run is
	// redone with them, still one step.
	keymap.command_args_reset(c)
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_value, 2)
	testing.expect_value(t, _t_runs, 3)
	testing.expect_value(t, len(s.items), 1)
	undo.apply_undo(s)
	testing.expect_value(t, _t_value, 0)
	undo.apply_redo(s)

	// Another step after it: the run is no longer the last one.
	other: int
	undo.push_value(s, undo.make_raw_target(&other, 0, int), undo.capture_json(&other, int), undo.capture_json(&_t_value, int), "Other")
	testing.expect(t, !editor.adjust_last_valid())
	(^_T_Args)(c.args).n = 6
	testing.expect(t, !editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_value, 2)

	// ask=true shows the arguments first and runs nothing.
	keymap.command_add_args("T Args/Adjust", _t_args_write, _T_ARGS_DEFAULT, id = "t.adjust", ask = true)
	_t_runs = 0
	keymap.command_run(c)
	testing.expect_value(t, _t_runs, 0)
	testing.expect(t, editor.adjust_last_command() == c)
	testing.expect(t, !editor.adjust_last_valid())
}

// The value the update test command treats as placed by its run, and how
// often its update applied a change in place.
@(private = "file")
_t_pos: f32
@(private = "file")
_t_updates: int
// Written only by the update, as a field the run never recorded.
@(private = "file")
_t_extra: f32

// Writes args.n into _t_value and args.v.x into _t_pos, each as an undo step.
@(private = "file")
_t_update_run :: proc(a: ^_T_Args) {
	_t_args_write(a)
	_t_set_pos(a.v.x)
}

// Moves _t_pos in place for a new v. A new n is not applied in place.
@(private = "file")
_t_update :: proc(a: ^_T_Args) -> bool {
	if a.n != _t_value do return false
	_t_updates += 1
	_t_set_pos(a.v.x)
	s := undo.get()
	old := undo.capture_json(&_t_extra, f32)
	_t_extra = a.v.y
	undo.push_value(s, undo.make_raw_target(&_t_extra, 0, f32), old, undo.capture_json(&_t_extra, f32), "Extra")
	return true
}

@(private = "file")
_t_set_pos :: proc(x: f32) {
	s := undo.get()
	old := undo.capture_json(&_t_pos, f32)
	_t_pos = x
	undo.push_value(s, undo.make_raw_target(&_t_pos, 0, f32), old, undo.capture_json(&_t_pos, f32), "Move")
}

// The subs of the entry on top of the stack.
@(private = "file")
_t_top_subs :: proc(s: ^undo.Undo_Stack) -> int {
	g, is_group := s.items[s.top - 1].cmd.(undo.Group_Command)
	return len(g.subs) if is_group else 1
}

@(test)
test_command_args_update_in_place :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	defer editor.adjust_last_close()
	defer keymap.command_remove("t.update")

	c := keymap.command_add_args("T Args/Update", _t_update_run, _T_ARGS_DEFAULT, id = "t.update", update = _t_update)
	testing.expect(t, c.update_args != nil)
	_t_value, _t_pos, _t_extra, _t_runs, _t_updates = 0, 0, 0, 0, 0

	keymap.command_run(c)
	testing.expect_value(t, _t_value, 2)
	testing.expect_value(t, _t_pos, 1)
	testing.expect_value(t, len(s.items), 1)
	run_subs := _t_top_subs(s)

	// A field the update applies: no run, the edits join the run's step. The
	// run already edited _t_pos, so that edit's new value is replaced. It did
	// not edit _t_extra, so that edit is appended.
	(^_T_Args)(c.args).v = {3, 7}
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_runs, 1)
	testing.expect_value(t, _t_updates, 1)
	testing.expect_value(t, _t_pos, 3)
	testing.expect_value(t, _t_extra, 7)
	testing.expect_value(t, len(s.items), 1)
	testing.expect_value(t, _t_top_subs(s), run_subs + 1)
	testing.expect(t, editor.adjust_last_valid())

	// Adjusted again, as on every frame of a drag: the edit is replaced, the
	// step does not grow.
	(^_T_Args)(c.args).v = {4, 8}
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_pos, 4)
	testing.expect_value(t, _t_extra, 8)
	testing.expect_value(t, _t_top_subs(s), run_subs + 1)
	testing.expect(t, editor.adjust_last_valid())

	// A field the update does not apply: the run is undone and runs again.
	(^_T_Args)(c.args).n = 5
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_runs, 2)
	testing.expect_value(t, _t_value, 5)
	testing.expect_value(t, _t_pos, 4)
	testing.expect_value(t, len(s.items), 1)

	// Moved in place again, then undone and redone as one step: undo puts
	// back what was there before the run, redo the moved value.
	(^_T_Args)(c.args).v = {6, 9}
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect_value(t, _t_runs, 2)
	undo.apply_undo(s)
	testing.expect_value(t, _t_value, 0)
	testing.expect_value(t, _t_pos, 0)
	testing.expect_value(t, _t_extra, 0)
	undo.apply_redo(s)
	testing.expect_value(t, _t_value, 5)
	testing.expect_value(t, _t_pos, 6)
	testing.expect_value(t, _t_extra, 9)
}
