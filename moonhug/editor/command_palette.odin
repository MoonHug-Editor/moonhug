package editor

// The command palette (docs/core/Keymaps.md): every command, filtered as
// you type, Enter runs the highlighted one. Window/Command Palette opens
// it. A modal widget like the dialog: it owns the keyboard while it is
// open, so its own keys are read here, and its empty modal keymap on the
// stack keeps every other binding quiet.

import "core:c"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"

@(private = "file")
_pal: struct {
	open_request: bool,
	shown:        bool, // the popup was open last frame: its keymap is pushed
	search:       [128]byte,
	highlight:    int,
	moved:        bool, // the highlight moved by key this frame: scroll to it
}

@(private = "file")
_PAL_WIDTH :: f32(640)
@(private = "file")
_PAL_LIST_HEIGHT :: f32(360)

@(menu_item={path="Window/Command Palette", order=-100, shortcut="Ctrl+Shift+A"})
command_palette_open :: proc() {
	_pal.open_request = true
}

// Empty: on the stack it silences every other keymap while the palette is
// open. The palette's own keys belong to the widget.
@(keymap={name="Command Palette", modal=true})
command_palette_keymap :: proc(km: ^keymap.Keymap) {
}

// One command as the palette lists it.
@(private = "file")
_Pal_Row :: struct {
	cmd:     ^keymap.Command,
	chords:  string, // the first two chords, formatted, "" for none
	enabled: bool,
}

// Drawn from the main loop after the views, like the dialog.
command_palette_draw :: proc() {
	km := keymap.find("Command Palette")
	if _pal.open_request {
		_pal.open_request = false
		im.OpenPopup("##command_palette")
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + 80}, .Appearing, {0.5, 0})
	if !im.BeginPopup("##command_palette") {
		if _pal.shown {
			_pal.shown = false
			if km != nil do keymap.pop(km)
		}
		return
	}
	defer im.EndPopup()
	if !_pal.shown {
		_pal.shown = true
		if km != nil do keymap.push(km)
	}
	if im.IsWindowAppearing() {
		_pal.search = {}
		_pal.highlight = 0
		im.SetKeyboardFocusHere()
	}
	if im.IsKeyPressed(.Escape, false) || widgets.text_input_escape_consumed() {
		im.CloseCurrentPopup()
		return
	}

	im.SetNextItemWidth(_PAL_WIDTH)
	if im.InputTextWithHint("##pal_search", "Command", cstring(raw_data(_pal.search[:])), c.size_t(len(_pal.search)), {}) {
		_pal.highlight = 0
	}
	query := strings.trim_space(string(cstring(raw_data(_pal.search[:]))))
	rows := _palette_rows(query)

	_pal.moved = false
	if im.IsKeyPressed(.DownArrow) {
		_pal.highlight += 1
		_pal.moved = true
	}
	if im.IsKeyPressed(.UpArrow) {
		_pal.highlight -= 1
		_pal.moved = true
	}
	_pal.highlight = clamp(_pal.highlight, 0, max(len(rows) - 1, 0))
	if len(rows) > 0 && (im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter)) {
		if _palette_run(rows[_pal.highlight]) do im.CloseCurrentPopup()
		return
	}

	im.Separator()
	if im.BeginChild("##pal_list", {_PAL_WIDTH, _PAL_LIST_HEIGHT}) {
		if len(rows) == 0 do im.TextDisabled("No command matches")
		for row, i in rows {
			im.PushIDPtr(row.cmd)
			im.BeginDisabled(!row.enabled)
			label := strings.clone_to_cstring(row.cmd.name, context.temp_allocator)
			if im.Selectable(label, i == _pal.highlight) {
				if _palette_run(row) do im.CloseCurrentPopup()
			}
			im.EndDisabled()
			if row.chords != "" {
				w := im.CalcTextSize(strings.clone_to_cstring(row.chords, context.temp_allocator)).x
				im.SameLine(_PAL_WIDTH - w - im.GetStyle().FramePadding.x * 2)
				im.TextDisabled("%s", strings.clone_to_cstring(row.chords, context.temp_allocator))
			}
			if i == _pal.highlight && _pal.moved do im.SetScrollHereY()
			im.PopID()
		}
	}
	im.EndChild()
}

// Runs a row's command when it can run. True when it ran.
@(private = "file")
_palette_run :: proc(row: _Pal_Row) -> bool {
	if !row.enabled do return false
	keymap.command_run(row.cmd)
	return true
}

// The commands matching `query`: every term, space separated, found in the
// name or the id, case ignored. Sorted by name. Temp.
@(private = "file")
_palette_rows :: proc(query: string) -> []_Pal_Row {
	terms := strings.fields(strings.to_lower(query, context.temp_allocator), context.temp_allocator)
	rows := make([dynamic]_Pal_Row, context.temp_allocator)
	for cmd in keymap.commands() {
		name := strings.to_lower(cmd.name, context.temp_allocator)
		id := strings.to_lower(cmd.id, context.temp_allocator)
		hit := true
		for term in terms do if !strings.contains(name, term) && !strings.contains(id, term) {
			hit = false
			break
		}
		if !hit do continue
		append(&rows, _Pal_Row{cmd = cmd, chords = _palette_chords(cmd), enabled = keymap.command_enabled(cmd)})
	}
	slice.sort_by(rows[:], proc(a, b: _Pal_Row) -> bool { return a.cmd.name < b.cmd.name })
	return rows[:]
}

// The first two chords bound to a command, in any keymap, as shown. Temp.
@(private = "file")
_palette_chords :: proc(cmd: ^keymap.Command) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for km in keymap.keymaps() do for &b in km.bindings {
		if len(out) == 2 do break
		if keymap.binding_command(&b) == cmd do append(&out, keymap.format_chord(b.chord))
	}
	return strings.join(out[:], ", ", context.temp_allocator)
}
