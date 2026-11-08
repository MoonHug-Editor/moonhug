package command_palette

// The command palette (docs/core/Keymaps.md): a popup over the editor that
// searches the rows of one mode and runs the picked one.
//
// - Commands are the mode with no prefix. Window/Command Palette opens it.
// - Every other mode is declared with @(command_palette_mode) and picked by
//   the prefix the text starts with: `#` assets, `@` scene objects, `:`
//   views.
//   Each mode has a command, Command Palette/<name>, that opens the palette
//   with its prefix typed.
// - `?`, typed alone, lists the modes with their chords
//   and the palette's keys.
//
// A modal widget like the dialog: it owns the keyboard while it is open, so
// its own keys are read here, and its empty modal keymap on the stack keeps
// every other binding quiet. The view focused when it opened stays the
// focused one while it is open, so a command's enabled state and its run are
// for that view.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"

// One row a mode lists. Its strings live at least until the frame ends.
Row :: struct {
	label:    string, // drawn on the left: what the search matched
	detail:   string, // drawn dimmed on the right: a chord, a folder, "" for none
	disabled: bool,   // drawn dimmed and never run: a command that cannot run now
	key:      string, // the row's identity for the mode's run proc: an asset path, a view key
	data:     rawptr, // the same for a mode that keeps a pointer: a command, a handle in temp memory
}

// Fills `rows` with the mode's rows that match `query`, the text after the
// prefix with spaces trimmed, in the order they are shown. Called every
// frame the mode is shown.
List_Proc :: proc(query: string, rows: ^[dynamic]Row)

// Acts on the picked row, in the frame it was listed. The palette closes
// after it.
Run_Proc :: proc(row: Row)

Mode :: struct {
	name:    string, // "Assets". Its command is Command Palette/<name>
	prefix:  string, // what the text starts with to search this mode, "" for commands
	list:    List_Proc,
	run:     Run_Proc,
	command: string, // the id of the command that opens the palette on this mode
	origin:  string,
}

// The text that shows the help instead of a mode's rows.
HELP :: "?"

// The id of the menu item that opens the palette on commands.
@(private = "file")
_COMMANDS_OPENER :: "editor.command_palette_open"

@(private = "file")
_commands_mode := Mode{
	name    = "Commands",
	list    = _commands_list,
	run     = _commands_run,
	command = _COMMANDS_OPENER,
}

@(private = "file")
_modes: [dynamic]^Mode

// The editor-wide keymap the modes' default chords go to, made by the first
// mode that has one.
KEYMAP :: "Command Palette Modes"

@(private = "file")
_pal: struct {
	open_request: bool,
	// The view focused when the palette opened: it stays the focused one for
	// the rows the palette lists and runs. Owned, "" for none.
	view:         string,
	shown:        bool, // the popup was open last frame: its keymap is pushed
	search:       [128]byte,
	// The search text was set from code: the field takes it on its next
	// frame, through its callback while it is being edited.
	replace:      bool,
	refocus:      bool, // the field gets the keyboard on its next frame
	highlight:    int,
	moved:        bool, // the highlight moved by key this frame: scroll to it
}

@(private = "file")
_PAL_WIDTH :: f32(640)
@(private = "file")
_PAL_LIST_HEIGHT :: f32(360)

// Declares a palette mode: the rows of one kind the palette searches, picked
// by the prefix the text starts with. A proc that lists them (List_Proc)
// declared with `@(command_palette_mode)` registers here through the generated
// _register_editor_keymaps.
//
// - `run` names the proc that acts on the picked row (Run_Proc).
// - The mode gets a command, Command Palette/<name>, that opens the palette
//   with its prefix typed. `shortcut` binds it in the editor-wide Command
//   Palette Modes keymap.
// - `id` is that command's stable id, the list proc's qualified name by
//   default.
// - A prefix that is empty, starts with `?` or is another mode's is a
//   declaration error: it panics with both origins.
@(extension_point={attribute="command_palette_mode", target="proc", fields="name prefix run shortcut id"})
mode_add :: proc(name: string, prefix: string, list: List_Proc, run: Run_Proc, shortcut := "", id := "", origin := "") -> ^Mode {
	context.allocator = runtime.default_allocator()
	if prefix == "" || strings.has_prefix(prefix, HELP) {
		panic(strings.concatenate({"command_palette: mode \"", name, "\" needs a prefix that is not empty and does not start with ", HELP, "  ", origin}, context.temp_allocator))
	}
	m: ^Mode
	for o in _modes {
		if o.name == name {
			m = o
			continue
		}
		if o.prefix == prefix {
			panic(strings.concatenate({"command_palette: prefix \"", prefix, "\" is declared twice, by ", o.name, " at ", o.origin, " and by ", name, " at ", origin}, context.temp_allocator))
		}
	}
	if m == nil {
		m = new(Mode)
		append(&_modes, m)
	} else {
		_mode_free_strings(m)
	}
	m.name = strings.clone(name)
	m.prefix = strings.clone(prefix)
	m.list = list
	m.run = run
	m.origin = strings.clone(origin)
	cmd := keymap.command_add_data(strings.concatenate({"Command Palette/", name}, context.temp_allocator), _mode_open, m, nil, origin, id)
	m.command = strings.clone(cmd.id)
	km := keymap.find(KEYMAP)
	// A re-registered mode binds once: drop its earlier binding.
	if km != nil do keymap.unbind(km, cmd.id)
	if shortcut != "" {
		if km == nil do km = keymap.add(KEYMAP, "", nil, origin = "moonhug/editor/command_palette/command_palette.odin")
		keymap.bind(km, shortcut, cmd.id)
	}
	slice.sort_by(_modes[:], proc(a, b: ^Mode) -> bool { return a.name < b.name })
	return m
}

// Removes the mode named `name` with its command and binding, for a plugin
// that goes away and for the tests.
mode_remove :: proc(name: string) {
	context.allocator = runtime.default_allocator()
	for m, i in _modes do if m.name == name {
		if km := keymap.find(KEYMAP); km != nil do keymap.unbind(km, m.command)
		keymap.command_remove(m.command)
		_mode_free_strings(m)
		free(m)
		ordered_remove(&_modes, i)
		return
	}
}

@(private = "file")
_mode_free_strings :: proc(m: ^Mode) {
	context.allocator = runtime.default_allocator()
	delete(m.name)
	delete(m.prefix)
	delete(m.command)
	delete(m.origin)
}

// Every mode, commands first, then the declared ones by name. Temp.
modes :: proc() -> []^Mode {
	out := make([]^Mode, len(_modes) + 1, context.temp_allocator)
	out[0] = &_commands_mode
	copy(out[1:], _modes[:])
	return out
}

// The mode `text` searches and the query after its prefix, spaces trimmed:
// the declared mode with the longest prefix the text starts with, else
// commands with the whole text.
mode_for :: proc(text: string) -> (m: ^Mode, query: string) {
	m = &_commands_mode
	query = text
	best := 0
	for o in _modes do if len(o.prefix) > best && strings.has_prefix(text, o.prefix) {
		m = o
		best = len(o.prefix)
		query = text[len(o.prefix):]
	}
	return m, strings.trim_space(query)
}

// Opens the palette with `prefix` typed, "" for commands. The view focused
// now stays the focused one while it is open.
open :: proc(prefix := "") {
	_pal.open_request = true
	_set_text(prefix)
	view := ""
	if w := wnd.focused(); w != nil do view = strings.clone(w.key, runtime.default_allocator())
	delete(_pal.view, runtime.default_allocator())
	_pal.view = view
}

@(private = "file")
_mode_open :: proc(data: rawptr) {
	open((^Mode)(data).prefix)
}

// The id is the one the menu item had in the editor package, so the
// user's bindings for it hold.
@(menu_item={path="Window/Command Palette", order=-100, shortcut="Ctrl+T", id="editor.command_palette_open"})
menu_open :: proc() {
	open()
}

// Empty: on the stack it silences every other keymap while the palette is
// open. The palette's own keys belong to the widget.
@(keymap={name="Command Palette", modal=true})
popup_keymap :: proc(km: ^keymap.Keymap) {
}

// Frees the modes and the palette's state, after the views and before the
// keymaps shut down.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for m in _modes {
		_mode_free_strings(m)
		free(m)
	}
	delete(_modes)
	_modes = nil
	delete(_pal.view)
	_pal.view = ""
}

// The query's terms, space separated and lowercased, for matches. Temp.
terms :: proc(query: string) -> []string {
	return widgets.search_terms(query)
}

// Whether `text` contains every term, case ignored. Allocates nothing, so a
// mode can test every row each frame.
matches :: proc(text: string, terms: []string) -> bool {
	for t in terms do if !contains_fold(text, t) do return false
	return true
}

// Whether `text` contains `lower`, a lowercased term, case ignored.
contains_fold :: proc(text: string, lower: string) -> bool {
	if len(lower) == 0 do return true
	for start := 0; start < len(text); {
		ti, li := start, 0
		for li < len(lower) && ti < len(text) {
			r, rn := utf8.decode_rune_in_string(text[ti:])
			l, ln := utf8.decode_rune_in_string(lower[li:])
			if unicode.to_lower(r) != l do break
			ti += rn
			li += ln
		}
		if li == len(lower) do return true
		if ti >= len(text) do return false
		_, n := utf8.decode_rune_in_string(text[start:])
		start += n
	}
	return false
}

// Sets the search text from code and puts the keyboard back in the field.
@(private = "file")
_set_text :: proc(text: string) {
	_pal.search = {}
	copy(_pal.search[:len(_pal.search) - 1], text)
	_pal.replace = true
	_pal.refocus = true
	_pal.highlight = 0
}

// The search field's callback: it takes text set from code while the field
// is being edited, since the field then keeps its own copy, and puts the
// cursor at the end, so a typed prefix is not selected and replaced by the
// next key.
@(private = "file")
_search_callback :: proc "c" (data: ^im.InputTextCallbackData) -> i32 {
	moved := data.EventActivated
	if _pal.replace {
		_pal.replace = false
		im.InputTextCallbackData_DeleteChars(data, 0, data.BufTextLen)
		im.InputTextCallbackData_InsertChars(data, 0, cstring(raw_data(_pal.search[:])))
		moved = true
	}
	if moved {
		data.CursorPos = data.BufTextLen
		data.SelectionStart = data.CursorPos
		data.SelectionEnd = data.CursorPos
	}
	return 0
}

// Drawn from the main loop after the views, like the dialog.
draw :: proc() {
	km := keymap.find("Command Palette")
	if _pal.open_request {
		_pal.open_request = false
		im.OpenPopup("##command_palette")
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + 180}, .Appearing, {0.5, 0})
	if !im.BeginPopup("##command_palette") {
		if _pal.shown {
			_pal.shown = false
			_pal.replace = false
			if km != nil do keymap.pop(km)
		}
		return
	}
	defer im.EndPopup()
	// The view below acts as the focused one while the palette is open, so
	// a command's enabled state and its run see it (View/Close).
	if _pal.view != "" do wnd.focused_hold(wnd.find(_pal.view))
	if !_pal.shown {
		_pal.shown = true
		if km != nil do keymap.push(km)
	}
	if im.IsWindowAppearing() do _pal.highlight = 0
	if im.IsKeyPressed(.Escape, false) || widgets.text_input_escape_consumed() {
		im.CloseCurrentPopup()
		return
	}

	text := string(cstring(raw_data(_pal.search[:])))
	mode, query := mode_for(text)
	style := im.GetStyle()
	mode_name := strings.clone_to_cstring(mode.name, context.temp_allocator)
	name_w := im.CalcTextSize(mode_name).x
	im.SetNextItemWidth(_PAL_WIDTH - name_w - style.ItemSpacing.x)
	if _pal.refocus || im.IsWindowAppearing() {
		_pal.refocus = false
		im.SetKeyboardFocusHere()
	}
	if im.InputTextWithHint("##pal_search", "Search, ? for help", cstring(raw_data(_pal.search[:])), uint(len(_pal.search)), {.CallbackAlways}, _search_callback) {
		_pal.highlight = 0
	}
	im.SameLine()
	im.TextDisabled("%s", mode_name)
	// The field may have changed the text.
	text = string(cstring(raw_data(_pal.search[:])))
	mode, query = mode_for(text)

	if text == HELP {
		_draw_help()
		return
	}

	rows := make([dynamic]Row, context.temp_allocator)
	mode.list(query, &rows)
	if _keys_move(len(rows)) {
		// A single-line field lets go of the keyboard on Enter: it gets it
		// back when the palette stays open.
		if _run(mode, rows[_pal.highlight]) do im.CloseCurrentPopup()
		else do _pal.refocus = true
		return
	}

	im.Separator()
	if im.BeginChild("##pal_list", {_PAL_WIDTH, _PAL_LIST_HEIGHT}) {
		if len(rows) == 0 do im.TextDisabled("Nothing matches")
		right := _PAL_WIDTH - style.FramePadding.x * 2
		clipper: im.ListClipper
		im.ListClipper_Begin(&clipper, i32(len(rows)))
		if _pal.moved && len(rows) > 0 do im.ListClipper_IncludeItemByIndex(&clipper, i32(_pal.highlight))
		for im.ListClipper_Step(&clipper) {
			for i in clipper.DisplayStart ..< clipper.DisplayEnd {
				row := rows[i]
				im.PushIDInt(i)
				im.BeginDisabled(row.disabled)
				label := strings.clone_to_cstring(row.label, context.temp_allocator)
				if im.Selectable(label, int(i) == _pal.highlight) {
					if _run(mode, row) do im.CloseCurrentPopup()
				}
				im.EndDisabled()
				if row.detail != "" {
					detail := strings.clone_to_cstring(row.detail, context.temp_allocator)
					x := max(right - im.CalcTextSize(detail).x, im.CalcTextSize(label).x + style.ItemSpacing.x * 4)
					im.SameLine(x)
					im.TextDisabled("%s", detail)
				}
				if int(i) == _pal.highlight && _pal.moved do im.SetScrollHereY()
				im.PopID()
			}
		}
	}
	im.EndChild()
}

// Moves the highlight on Up and Down within `count` rows. True when Enter
// picks the highlighted one.
@(private = "file")
_keys_move :: proc(count: int) -> bool {
	_pal.moved = false
	if im.IsKeyPressed(.DownArrow) {
		_pal.highlight += 1
		_pal.moved = true
	}
	if im.IsKeyPressed(.UpArrow) {
		_pal.highlight -= 1
		_pal.moved = true
	}
	_pal.highlight = clamp(_pal.highlight, 0, max(count - 1, 0))
	return count > 0 && (im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter))
}

// Runs a row of `mode` when it can run. True when it ran.
@(private = "file")
_run :: proc(mode: ^Mode, row: Row) -> bool {
	if row.disabled do return false
	mode.run(row)
	return true
}

// The help: every mode with its prefix and its command's chord, a row of
// which switches to that mode, then the palette's keys.
@(private = "file")
_draw_help :: proc() {
	all := modes()
	if _keys_move(len(all)) {
		_switch_to(all[_pal.highlight])
		return
	}
	im.Separator()
	if !im.BeginChild("##pal_help", {_PAL_WIDTH, _PAL_LIST_HEIGHT}) {
		im.EndChild()
		return
	}
	defer im.EndChild()
	im.TextDisabled("Modes: type the prefix, then the search")
	// Laid out like the result rows: the chord right-aligned, the prefix in
	// a column left of the widest chord.
	style := im.GetStyle()
	right := _PAL_WIDTH - style.FramePadding.x * 2
	chords := make([]cstring, len(all), context.temp_allocator)
	chord_w, prefix_w: f32
	for m, i in all {
		chord := keymap.hint(m.command)
		chords[i] = strings.clone_to_cstring(chord if chord != "" else "no shortcut", context.temp_allocator)
		chord_w = max(chord_w, im.CalcTextSize(chords[i]).x)
		prefix_w = max(prefix_w, im.CalcTextSize(_prefix_text(m)).x)
	}
	chord_x := right - chord_w
	prefix_x := chord_x - style.ItemSpacing.x * 4 - prefix_w
	for m, i in all {
		im.PushIDInt(i32(i))
		if im.Selectable(strings.clone_to_cstring(m.name, context.temp_allocator), i == _pal.highlight) do _switch_to(m)
		im.PopID()
		im.SameLine(prefix_x)
		im.TextUnformatted(_prefix_text(m))
		im.SameLine(right - im.CalcTextSize(chords[i]).x)
		im.TextDisabled("%s", chords[i])
	}
	im.Spacing()
	im.TextDisabled("Keys")
	if im.BeginTable("##pal_keys", 2, im.TableFlags_SizingStretchProp) {
		im.TableSetupColumn("Key", {.WidthFixed})
		im.TableSetupColumn("Does", {.WidthStretch})
		keys := [?][2]cstring{
			{"Up, Down", "Move the highlight"},
			{"Enter", "Run the highlighted row, or switch to the highlighted mode here"},
			{"Escape", "Close the palette"},
			{HELP, "Show this help, typed alone in the field"},
		}
		for k in keys {
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			im.TextUnformatted(k[0])
			im.TableSetColumnIndex(1)
			im.TextUnformatted(k[1])
		}
		im.EndTable()
	}
}

// A mode's prefix as the help shows it.
@(private = "file")
_prefix_text :: proc(m: ^Mode) -> cstring {
	return strings.clone_to_cstring(m.prefix if m.prefix != "" else "none", context.temp_allocator)
}

// Leaves the help for `m`: its prefix is typed, the search after it empty.
@(private = "file")
_switch_to :: proc(m: ^Mode) {
	_set_text(m.prefix)
}

// The commands mode: every command the palette lists (keymap.in_palette)
// whose name holds every term, or whose id does for a term with a dot, by
// name, with its first two chords.
@(private = "file")
_commands_list :: proc(query: string, rows: ^[dynamic]Row) {
	ts := terms(query)
	for cmd in keymap.commands() {
		if !keymap.in_palette(cmd) do continue
		// The name, and the id only for a term that reads as one (it has a
		// dot): ids carry package names, scene_views, that would match
		// "view" everywhere.
		hit := true
		for term in ts {
			if contains_fold(cmd.name, term) do continue
			if strings.contains(term, ".") && contains_fold(cmd.id, term) do continue
			hit = false
			break
		}
		if !hit do continue
		append(rows, Row{label = cmd.name, detail = _chords(cmd), disabled = !keymap.command_enabled(cmd), data = cmd})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.label < b.label })
}

@(private = "file")
_commands_run :: proc(row: Row) {
	keymap.command_run((^keymap.Command)(row.data))
}

// The first two chords bound to a command, in any keymap, as shown. Temp.
@(private = "file")
_chords :: proc(cmd: ^keymap.Command) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for km in keymap.keymaps() do for &b in km.bindings {
		if len(out) == 2 do break
		if keymap.binding_command(&b) == cmd do append(&out, keymap.format_chord(b.chord))
	}
	return strings.join(out[:], ", ", context.temp_allocator)
}
