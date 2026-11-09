package editor

// The settings panel of a command with arguments (docs/core/Keymaps.md,
// "Commands with arguments"). The command runs at once with the values it
// last used, as one undo step, and this panel then shows those values at the
// bottom left of the editor, without taking the keyboard or blocking any
// window. Changing a value undoes that step and runs the command again with
// the new values, unless the command's update proc applies the change to
// what the run made, in place. Reset puts the declared defaults back, which
// is a change like any other. Anything else that records an undo step, an
// undo or a redo closes the panel: the step it would replace is no longer the
// last one. A command declared ask=true opens the panel before it runs, with
// a Run button.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "inspector"
import "moonhug:editor/icons"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"
import "undo"

@(private = "file")
_ADJUST_WIDTH :: f32(320)

@(private = "file")
_adjust: struct {
	cmd:    ^keymap.Command, // the command the panel shows, nil when it is closed
	asking: bool,            // ask=true, not run yet: Run instead of running on an edit
	mark:   u64,             // the undo stack's mutation count right after the run
	ran:    []byte,          // its arguments as they ran, to see an edit. Owned
}

@(init, private = "file")
_adjust_install :: proc "contextless" () {
	keymap.args_runner = _adjust_runner
}

// keymap.command_run's way to run a command with arguments.
@(private = "file")
_adjust_runner :: proc(c: ^keymap.Command) {
	if c.ask {
		_adjust_show(c, asking = true)
		return
	}
	adjust_last_run(c)
}

// Runs `c` with its arguments as one undo step and shows the panel for it.
// A run that recorded nothing changed nothing, so it has nothing to adjust
// and the panel closes. Without an undo stack the command just runs.
adjust_last_run :: proc(c: ^keymap.Command) {
	s := undo.get()
	if s == nil {
		c.run_args(c.args)
		return
	}
	before := s.mutations
	g := undo.group_begin(_adjust_title(c))
	c.run_args(c.args)
	if s.mutations != before do undo.group_commit(&g)
	undo.group_end(&g)
	if s.mutations == before {
		adjust_last_close()
		return
	}
	_adjust_show(c, asking = false)
	_adjust.mark = s.mutations
}

// The command the panel shows, nil when it is closed.
adjust_last_command :: proc() -> ^keymap.Command {
	return _adjust.cmd
}

// Whether the panel's run is still the last undo step: nothing was recorded,
// undone or redone since it ran.
adjust_last_valid :: proc() -> bool {
	s := undo.get()
	return _adjust.cmd != nil && !_adjust.asking && s != nil && s.mutations == _adjust.mark
}

// Applies the arguments when they changed since the command last ran. A
// command with an update proc gets the first try: it changes what the run
// made in place, and its edits become part of the run's undo step. Otherwise
// the last run is undone and the command runs again, so the new run replaces
// it. True when the change was applied.
adjust_last_apply_edit :: proc() -> bool {
	c := _adjust.cmd
	if c == nil || _adjust.asking || !adjust_last_valid() do return false
	cur := undo.capture_json(c.args, c.args_type)
	defer delete(cur)
	if slice.equal(cur, _adjust.ran) do return false
	if c.update_args != nil && _adjust_update(c) do return true
	s := undo.get()
	if !undo.apply_undo(s) do return false
	adjust_last_run(c)
	return true
}

// The command's update proc, its edits folded into the run's undo step. False
// when it does not apply this change in place: it changed nothing then, and
// the group it would have recorded into is dropped.
@(private = "file")
_adjust_update :: proc(c: ^keymap.Command) -> bool {
	s := undo.get()
	g := undo.amend_begin(_adjust_title(c))
	updated := c.update_args(c.args)
	if updated do undo.group_commit(&g)
	undo.group_end(&g)
	if !updated do return false
	context.allocator = runtime.default_allocator()
	delete(_adjust.ran)
	_adjust.ran = undo.capture_json(c.args, c.args_type)
	_adjust.mark = s.mutations
	return true
}

adjust_last_close :: proc() {
	context.allocator = runtime.default_allocator()
	delete(_adjust.ran)
	_adjust = {}
}

@(private = "file")
_adjust_show :: proc(c: ^keymap.Command, asking: bool) {
	context.allocator = runtime.default_allocator()
	delete(_adjust.ran)
	_adjust.cmd = c
	_adjust.asking = asking
	_adjust.ran = undo.capture_json(c.args, c.args_type)
}

// The command's title, the part of its name after the last slash.
@(private = "file")
_adjust_title :: proc(c: ^keymap.Command) -> string {
	return c.name[strings.last_index_byte(c.name, '/') + 1:]
}

// Drawn from the main loop after the windows, like the command palette: a small
// window at the bottom left of the editor, titled with the command, its
// arguments drawn by the inspector. It never takes the keyboard when it
// appears, and collapses to its title bar.
adjust_last_draw :: proc() {
	c := _adjust.cmd
	if c == nil do return
	if !_adjust.asking && !adjust_last_valid() {
		adjust_last_close()
		return
	}
	vp := im.GetMainViewport()
	pad := im.GetStyle().WindowPadding
	im.SetNextWindowPos({vp.WorkPos.x + pad.x, vp.WorkPos.y + vp.WorkSize.y - pad.y}, .Always, {0, 1})
	// A fixed width: inspector rows fill the width they get, so an
	// auto-resized width would grow every frame. The height fits the rows.
	im.SetNextWindowSizeConstraints({_ADJUST_WIDTH, 0}, {_ADJUST_WIDTH, max(f32)})
	flags := im.WindowFlags{.NoMove, .NoResize, .AlwaysAutoResize, .NoSavedSettings, .NoFocusOnAppearing, .NoDocking}
	visible := im.Begin(fmt.ctprintf("%s###adjust_last", _adjust_title(c)), nil, flags)
	defer im.End()
	if !visible do return
	_reset_button(c)

	// The arguments are the command's, not part of any document: an edit
	// records no undo step of its own. The run does.
	undo.push_owner({kind = .None})
	inspector.draw_inspector(any{c.args, c.args_type})
	undo.pop_owner()

	if _adjust.asking {
		if im.Button("Run") do adjust_last_run(c)
		return
	}
	adjust_last_apply_edit()
}

// Reset, an icon at the right of the panel's title bar: puts the command's
// declared defaults back, a change like any other. Disabled while the values
// are the defaults. Drawn in the title bar through a clip rect around it, then
// the cursor goes back to where the panel's rows start.
@(private = "file")
_reset_button :: proc(c: ^keymap.Command) {
	style := im.GetStyle()
	pos, size := im.GetWindowPos(), im.GetWindowSize()
	w := im.CalcTextSize(icons.ICON_MD_REFRESH).x + style.FramePadding.x * 2
	rows := im.GetCursorScreenPos()
	im.PushClipRect(pos, {pos.x + size.x, pos.y + im.GetFrameHeight()}, false)
	im.SetCursorScreenPos({pos.x + size.x - style.FramePadding.x - w, pos.y + style.FramePadding.y})
	at_defaults := runtime.memory_compare(c.args, c.args_default, type_info_of(c.args_type).size) == 0
	im.BeginDisabled(at_defaults)
	im.PushStyleColor(.Button, 0)
	if im.SmallButton(icons.ICON_MD_REFRESH) do keymap.command_args_reset(c)
	im.PopStyleColor()
	im.EndDisabled()
	widgets.tooltip("Reset to defaults" if !at_defaults else "The settings are the defaults", im.HoveredFlags_AllowWhenDisabled)
	im.PopClipRect()
	im.SetCursorScreenPos(rows)
}
