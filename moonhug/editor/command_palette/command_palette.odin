package command_palette

// The command palette (docs/core/Keymaps.md): a popup over the editor that
// searches the rows of one mode and runs the picked one.
//
// - Commands are the mode with no prefix. Window/Command Palette opens it.
// - Every other mode is declared with @(command_palette_mode) and picked by
//   the prefix the text starts with: `#` assets, `@` scene objects, `:`
//   windows.
//   Each mode has a command, Command Palette/<name>, that opens the palette
//   with its prefix typed.
// - `?`, typed alone, lists the modes with their chords
//   and the palette's keys.
// - Rows are ranked by how the query matches their labels (matches), then
//   the ones that can run first, then the recently run first, then in the
//   order the mode lists them. With no
//   query the recently run come first. The editor settings keep the recent
//   rows.
//
// A modal widget like the dialog: it owns the keyboard while it is open, so
// its own keys are read here, and its empty modal keymap on the stack keeps
// every other binding quiet. The window focused when it opened stays the
// focused one while it is open, so a command's enabled state and its run are
// for that window.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"

// One row a mode lists. Its strings live at least until the frame ends.
Row :: struct {
	icon:     string, // a glyph drawn before the label, "" for none
	label:    string, // drawn on the left: what the search matched
	detail:   string, // drawn dimmed on the right: a chord, a folder, "" for none
	help:     string, // drawn dimmed on a second line under the label: one sentence on what the row does, "" for none
	disabled: bool,   // drawn dimmed and never run: a command that cannot run now
	reason:   string, // why a disabled row cannot run, drawn on the second line in place of help, "" for none
	// The row's identity for the mode's run proc, and for the recently run
	// rows: an asset path, a window key, a command id. "" for a row that is
	// never ranked as recent.
	key:      string,
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
	// The window focused when the palette opened: it stays the focused one for
	// the rows the palette lists and runs. Owned, "" for none.
	window:       string,
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
// The size the row icons draw at, from the large icon font.
@(private = "file")
_ICON_SIZE :: f32(widgets.FONT_SIZE + 3)
// The colour of the reason a disabled row cannot run.
@(private = "file")
_REASON_COLOR :: im.Vec4{1, 0.8, 0.3, 1}

// The recently run rows of each mode, most recent first, by mode name: their
// Row.key values. Keys and values owned.
@(private = "file")
_recent: map[string][dynamic]string

// How many recently run rows a mode keeps.
RECENT_MAX :: 20

// One mode's recently run rows, as the editor settings save them.
Recent :: struct {
	mode: string,
	keys: []string,
}

// Declares a palette mode: the rows of one kind the palette searches, picked
// by the prefix the text starts with. A proc that lists them (List_Proc)
// declared with `@(command_palette_mode)` registers here through the generated
// _register_editor_keymaps.
//
// - `run` names the proc that acts on the picked row (Run_Proc).
// - The mode gets a command, Command Palette/<name>, that opens the palette
//   with its prefix typed. `shortcut` binds it in the editor-wide Command
//   Palette Modes keymap: a chord, or several separated by a comma and a
//   space.
// - `id` is that command's stable id, the list proc's qualified name by
//   default. `help` is that command's help.
// - A prefix that is empty, starts with `?` or is another mode's is a
//   declaration error: it panics with both origins.
@(extension_point={attribute="command_palette_mode", target="proc", fields="name prefix run shortcut id help"})
mode_add :: proc(name: string, prefix: string, list: List_Proc, run: Run_Proc, shortcut := "", id := "", origin := "", help := "") -> ^Mode {
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
	cmd := keymap.command_add_data(strings.concatenate({"Command Palette/", name}, context.temp_allocator), _mode_open, m, nil, origin, id, help = help)
	m.command = strings.clone(cmd.id)
	km := keymap.find(KEYMAP)
	// A re-registered mode binds once: drop its earlier binding.
	if km != nil do keymap.unbind(km, cmd.id)
	if shortcut != "" {
		if km == nil do km = keymap.add(KEYMAP, "", nil, origin = "moonhug/editor/command_palette/command_palette.odin")
		for chord in keymap.split_chords(shortcut) do keymap.bind(km, chord, cmd.id)
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

// Opens the palette with `prefix` typed, "" for commands. The window focused
// now stays the focused one while it is open.
open :: proc(prefix := "") {
	_pal.open_request = true
	_set_text(prefix)
	window := ""
	if w := wnd.focused(); w != nil do window = strings.clone(w.key, runtime.default_allocator())
	delete(_pal.window, runtime.default_allocator())
	_pal.window = window
}

@(private = "file")
_mode_open :: proc(data: rawptr) {
	open((^Mode)(data).prefix)
}

// The id is the one the menu item had in the editor package, so the
// user's bindings for it hold. The second chord is the key left of 1: imgui
// maps it by position, so it is that key on every layout, whatever it types.
@(menu_item={path="Window/Command Palette", order=-100, shortcut="Ctrl+T, `", id="editor.command_palette_open", help="Searches the commands and runs one. Type ? for the other modes"})
menu_open :: proc() {
	open()
}

// Empty: on the stack it silences every other keymap while the palette is
// open. The palette's own keys belong to the widget.
@(keymap={name="Command Palette", modal=true})
popup_keymap :: proc(km: ^keymap.Keymap) {
}

// Frees the modes and the palette's state, after the windows and before the
// keymaps shut down.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for m in _modes {
		_mode_free_strings(m)
		free(m)
	}
	delete(_modes)
	_modes = nil
	_recent_clear()
	delete(_recent)
	_recent = nil
	delete(_pal.window)
	_pal.window = ""
}

// Replaces the recently run rows with `list`, from the editor settings at
// startup. Each mode keeps its first RECENT_MAX keys.
recent_load :: proc(list: []Recent) {
	_recent_clear()
	context.allocator = runtime.default_allocator()
	for r in list {
		if r.mode in _recent do continue
		keys := make([dynamic]string, 0, min(len(r.keys), RECENT_MAX))
		for k in r.keys[:min(len(r.keys), RECENT_MAX)] do append(&keys, strings.clone(k))
		_recent[strings.clone(r.mode)] = keys
	}
}

// The recently run rows of every mode, by mode name, for the editor
// settings to save. Temp, its strings the palette's.
recent_saved :: proc() -> []Recent {
	out := make([dynamic]Recent, context.temp_allocator)
	for mode, keys in _recent do append(&out, Recent{mode, keys[:]})
	slice.sort_by(out[:], proc(a, b: Recent) -> bool { return a.mode < b.mode })
	return out[:]
}

// The recently run rows of the mode named `mode`, most recent first.
recent :: proc(mode: string) -> []string {
	keys, _ := _recent[mode]
	return keys[:]
}

// Puts `key` first in the recently run rows of `mode`.
@(private = "file")
_recent_push :: proc(mode: string, key: string) {
	context.allocator = runtime.default_allocator()
	// The map keeps the key it was first set with, so the name is cloned
	// once.
	if mode not_in _recent do _recent[strings.clone(mode)] = nil
	keys := _recent[mode]
	for k, i in keys do if k == key {
		delete(k)
		ordered_remove(&keys, i)
		break
	}
	inject_at(&keys, 0, strings.clone(key))
	for len(keys) > RECENT_MAX do delete(pop(&keys))
	_recent[mode] = keys
}

@(private = "file")
_recent_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for mode, keys in _recent {
		for k in keys do delete(k)
		delete(keys)
		delete(mode)
	}
	clear(&_recent)
}

// The query's terms, space separated and lowercased, for matches. Temp.
terms :: proc(query: string) -> []string {
	return widgets.search_terms(query)
}

// Whether every term matches `text`, case ignored. A term matches as a
// substring, or as prefixes of the text's words in order: `fs` and `frsel`
// match Frame Selected. A word starts after a character that is not a
// letter or a digit, at an uppercase letter after a lowercase one, and at a
// digit after a letter. Allocates nothing, so a mode can test every row each
// frame. Pass one term as terms[i:i + 1].
matches :: proc(text: string, terms: []string) -> bool {
	_, all := _score(text, terms)
	return all
}

// Whether `text` contains `lower`, a lowercased term, case ignored.
contains_fold :: proc(text: string, lower: string) -> bool {
	if len(lower) == 0 do return true
	for start := 0; start < len(text); {
		if _prefix_fold(text[start:], lower) > 0 do return true
		_, n := utf8.decode_rune_in_string(text[start:])
		start += n
	}
	return false
}

// How a term matched, best first. A row ranks by the sum over its terms.
@(private = "file")
_SCORE_TITLE_START :: 100 // a substring at the start of the title, the text after the last slash
@(private = "file")
_SCORE_TITLE_WORD :: 80 // a substring at the start of a word of the title
@(private = "file")
_SCORE_GROUP_WORD :: 70 // a substring at the start of a word before the title
@(private = "file")
_SCORE_TITLE_PREFIXES :: 60 // prefixes of words of the title in order, 5 more from its first word
@(private = "file")
_SCORE_PREFIXES :: 50 // prefixes of words in order, reaching before the title
@(private = "file")
_SCORE_INSIDE :: 20 // a substring inside a word
@(private = "file")
_SCORE_WHOLE_WORD :: 5 // added when a substring at a word start is the whole word

// The words of a text the prefix match looks at, and the bytes of a term.
@(private = "file")
_MAX_WORDS :: 64
@(private = "file")
_MAX_TERM :: 32

// A matched byte range of a label, for the highlight.
@(private = "file")
_Span :: struct {
	lo, hi: int,
}

// How well the terms match `text`: the sum of each term's score, and whether
// every term matched. The matched ranges go to `spans` when it is not nil.
@(private = "file")
_score :: proc(text: string, ts: []string, spans: ^[dynamic]_Span = nil) -> (score: int, all: bool) {
	buf: [_MAX_WORDS]int
	starts := buf[:_word_starts(text, &buf)]
	title := strings.last_index_byte(text, '/') + 1
	all = true
	for t in ts {
		s := _term_score(text, t, title, starts, spans)
		if s == 0 do all = false
		score += s
	}
	return
}

// How well `term` matches `text`, 0 for not at all: its best substring, else
// prefixes of words, of the title's words first. `title` is where the title
// starts, `starts` where the words start.
@(private = "file")
_term_score :: proc(text: string, term: string, title: int, starts: []int, spans: ^[dynamic]_Span) -> int {
	if term == "" do return _SCORE_INSIDE
	best, at, n := 0, 0, 0
	for s := 0; s < len(text); {
		if m := _prefix_fold(text[s:], term); m > 0 {
			score := _SCORE_INSIDE
			if slice.contains(starts, s) {
				switch {
				case s == title: score = _SCORE_TITLE_START
				case s > title:  score = _SCORE_TITLE_WORD
				case:            score = _SCORE_GROUP_WORD
				}
				if end := s + m; end == len(text) || slice.contains(starts, end) {
					score += _SCORE_WHOLE_WORD
				} else if r, _ := utf8.decode_rune_in_string(text[end:]); !_is_word_rune(r) {
					score += _SCORE_WHOLE_WORD
				}
			}
			if score > best do best, at, n = score, s, m
		}
		_, w := utf8.decode_rune_in_string(text[s:])
		s += w
	}
	if best < _SCORE_TITLE_PREFIXES && len(term) <= _MAX_TERM && _all_word_runes(term) {
		in_title := 0
		for in_title < len(starts) && starts[in_title] < title do in_title += 1
		memo: [_MAX_TERM]u64
		if first := _prefixes(text, term, 0, 0, starts[in_title:], &memo, spans); first >= 0 {
			return _SCORE_TITLE_PREFIXES + (_SCORE_WHOLE_WORD if first == title else 0)
		}
		if in_title > 0 {
			memo = {}
			if _prefixes(text, term, 0, 0, starts, &memo, spans) >= 0 do return _SCORE_PREFIXES
		}
	}
	if best > 0 && spans != nil do append(spans, _Span{at, at + n})
	return best
}

// Whether term[ti:] is a run of prefixes, one letter or more each, of the
// words from starts[wi] on, in order: where its first prefix starts, -1 for
// no match. The longest prefix of a word is tried first. Bit wi of memo[ti]
// marks a pair known to fail. On a match the ranges go to `spans` when it is
// not nil.
@(private = "file")
_prefixes :: proc(text: string, term: string, ti, wi: int, starts: []int, memo: ^[_MAX_TERM]u64, spans: ^[dynamic]_Span) -> int {
	if ti == len(term) do return len(text)
	if memo[ti] & (u64(1) << uint(wi)) != 0 do return -1
	for w in wi ..< len(starts) {
		s := starts[w]
		limit := starts[w + 1] if w + 1 < len(starts) else len(text)
		// How far the term runs along the word: after k runes, the term is
		// at term_at[k] and the text at text_at[k].
		term_at, text_at: [_MAX_TERM + 1]int
		k, x, t := 0, s, ti
		for t < len(term) && x < limit {
			r, rn := utf8.decode_rune_in_string(text[x:])
			if !_is_word_rune(r) do break
			l, ln := utf8.decode_rune_in_string(term[t:])
			if unicode.to_lower(r) != l do break
			x += rn
			t += ln
			k += 1
			term_at[k], text_at[k] = t, x
		}
		for j := k; j >= 1; j -= 1 {
			if _prefixes(text, term, term_at[j], w + 1, starts, memo, spans) >= 0 {
				if spans != nil do append(spans, _Span{s, text_at[j]})
				return s
			}
		}
	}
	memo[ti] |= u64(1) << uint(wi)
	return -1
}

// The byte offsets where the words of `text` start, at most _MAX_WORDS.
@(private = "file")
_word_starts :: proc(text: string, out: ^[_MAX_WORDS]int) -> int {
	n := 0
	prev: rune = 0
	for r, i in text {
		if n == _MAX_WORDS do break
		if _is_word_rune(r) {
			if !_is_word_rune(prev) || (unicode.is_upper(r) && unicode.is_lower(prev)) || (unicode.is_digit(r) && unicode.is_letter(prev)) {
				out[n] = i
				n += 1
			}
		}
		prev = r
	}
	return n
}

@(private = "file")
_is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r)
}

@(private = "file")
_all_word_runes :: proc(s: string) -> bool {
	for r in s do if !_is_word_rune(r) do return false
	return true
}

// The bytes of `text` that `lower`, a lowercased term, matches at its start,
// case ignored. 0 when it does not match there.
@(private = "file")
_prefix_fold :: proc(text: string, lower: string) -> int {
	ti, li := 0, 0
	for li < len(lower) {
		if ti >= len(text) do return 0
		r, rn := utf8.decode_rune_in_string(text[ti:])
		l, ln := utf8.decode_rune_in_string(lower[li:])
		if unicode.to_lower(r) != l do return 0
		ti += rn
		li += ln
	}
	return ti
}

// The rows the palette shows for `text`, in the order it shows them: the
// mode the text picks lists them, then they are ranked. Temp.
rows_for :: proc(text: string) -> []Row {
	mode, query := mode_for(text)
	rows := make([dynamic]Row, context.temp_allocator)
	mode.list(query, &rows)
	_rank(mode, query, rows[:])
	return rows[:]
}

// Orders the rows `mode` listed for `query`: by how well the query matches
// each label, then the rows that can run first, then the recently run first,
// then in the order the mode listed them. A row the mode listed for a match outside its label (an asset's
// folder) ranks by the terms its label matches.
@(private = "file")
_rank :: proc(mode: ^Mode, query: string, rows: []Row) {
	ts := terms(query)
	recent_keys := recent(mode.name)
	Key :: struct {
		score, recent, index: int,
		disabled:            bool,
	}
	keys := make([]Key, len(rows), context.temp_allocator)
	for r, i in rows {
		score, _ := _score(r.label, ts)
		at := len(recent_keys)
		if r.key != "" do for k, j in recent_keys do if k == r.key {
			at = j
			break
		}
		keys[i] = {score, at, i, r.disabled}
	}
	slice.sort_by(keys, proc(a, b: Key) -> bool {
		if a.score != b.score do return a.score > b.score
		if a.disabled != b.disabled do return !a.disabled
		if a.recent != b.recent do return a.recent < b.recent
		return a.index < b.index
	})
	sorted := make([]Row, len(rows), context.temp_allocator)
	for k, i in keys do sorted[i] = rows[k.index]
	copy(rows, sorted)
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

// Drawn from the main loop after the windows, like the dialog.
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
	// The window below acts as the focused one while the palette is open, so
	// a command's enabled state and its run see it (Window/Close).
	if _pal.window != "" do wnd.focused_hold(wnd.find(_pal.window))
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

	rows := rows_for(text)
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
		ts := terms(query)
		style := im.GetStyle()
		line, gap := im.GetTextLineHeight(), style.ItemSpacing.y
		// A mode whose rows have icons gets an icon column on every row, so
		// the labels line up.
		icon_w: f32
		for r in rows do if r.icon != "" {
			im.PushFontFloat(widgets.icon_font_lg, _ICON_SIZE)
			icon_w = im.CalcTextSize(icons.ICON_MD_STACKS).x + style.ItemSpacing.x
			im.PopFont()
			break
		}
		// A row is one line, or two with a note, so its height comes from its
		// data: top[i] is where row i starts, below the first row's top. Only
		// the rows in view are drawn.
		top := make([]f32, len(rows) + 1, context.temp_allocator)
		for r, i in rows do top[i + 1] = top[i] + _row_height(r, line) + gap
		base := im.GetCursorPosY()
		scroll, visible_h := im.GetScrollY(), im.GetWindowHeight()
		// The highlight moved by key comes into view, from the next frame.
		if h := _pal.highlight; _pal.moved && h < len(rows) {
			if base + top[h] < scroll + style.WindowPadding.y {
				im.SetScrollY(max(base + top[h] - style.WindowPadding.y, 0))
			} else if base + top[h + 1] - gap > scroll + visible_h - style.WindowPadding.y {
				im.SetScrollY(base + top[h + 1] - gap + style.WindowPadding.y - visible_h)
			}
		}
		first := 0
		for first < len(rows) && base + top[first + 1] <= scroll do first += 1
		for i := first; i < len(rows) && base + top[i] < scroll + visible_h; i += 1 {
			im.SetCursorPosY(base + top[i])
			im.PushIDInt(i32(i))
			if _draw_row(rows[i], ts, i == _pal.highlight, i % 2 == 1, line, icon_w) {
				if _run(mode, rows[i]) do im.CloseCurrentPopup()
			}
			im.PopID()
		}
		// The rows below the window still count for the scrollbar.
		if len(rows) > 0 {
			im.SetCursorPosY(base + top[len(rows)] - gap)
			im.Dummy({0, 0})
		}
	}
	im.EndChild()
}

// What a row shows on its second line: why a disabled row cannot run, else
// its help. "" for a row of one line.
@(private = "file")
_row_note :: proc(row: Row) -> string {
	if row.disabled && row.reason != "" do return row.reason
	return row.help
}

@(private = "file")
_row_height :: proc(row: Row, line: f32) -> f32 {
	return line * 2 if _row_note(row) != "" else line
}

// Draws one result row: the label with the letters the terms matched in the
// accent colour, the detail right-aligned, and under the label the note,
// the help dimmed or the reason a disabled row cannot run in its own colour.
// An `alt` row has the theme's alternate row background, so rows of one and
// two lines stay apart. `icon_w` is the icon column's width, 0 for a mode
// without icons: the label and the note start after it. A note cut short
// shows whole in the tooltip. True when the row was clicked.
@(private = "file")
_draw_row :: proc(row: Row, ts: []string, selected: bool, alt: bool, line: f32, icon_w: f32) -> (clicked: bool) {
	style := im.GetStyle()
	row_pos := im.GetCursorScreenPos()
	pos := row_pos + {icon_w, 0}
	right := row_pos.x + im.GetContentRegionAvail().x
	dl := im.GetWindowDrawList()
	note := _row_note(row)

	// The band covers what the selectable's highlight covers, half the item
	// spacing past the row on every side, so neighbouring bands meet.
	if alt {
		half := style.ItemSpacing * 0.5
		im.DrawList_AddRectFilled(dl, row_pos - half, {right, pos.y + _row_height(row, line)} + half, im.GetColorU32(.TableRowBgAlt))
	}

	// The selectable has no text of its own: the row's is drawn over it.
	// Colours taken inside the disabled block come out dimmed.
	im.BeginDisabled(row.disabled)
	clicked = im.Selectable("##row", selected, {}, {0, _row_height(row, line)})
	if row.icon != "" {
		// The large icon font a little above text size, as the Hierarchy
		// draws its glyphs, centred on the label's line.
		im.PushFontFloat(widgets.icon_font_lg, _ICON_SIZE)
		icon := strings.clone_to_cstring(row.icon, context.temp_allocator)
		im.DrawList_AddText(dl, {row_pos.x, row_pos.y - (_ICON_SIZE - widgets.FONT_SIZE) * 0.5}, im.GetColorU32(.Text), icon)
		im.PopFont()
	}
	label_w := _draw_label(dl, pos, row.label, ts)
	if row.detail != "" {
		detail := strings.clone_to_cstring(row.detail, context.temp_allocator)
		x := max(right - im.CalcTextSize(detail).x, pos.x + label_w + style.ItemSpacing.x * 4)
		im.DrawList_AddText(dl, {x, pos.y}, im.GetColorU32(.TextDisabled), detail)
	}
	note_col := im.GetColorU32(.TextDisabled)
	im.EndDisabled()
	if note == "" do return
	if row.disabled && row.reason != "" do note_col = im.GetColorU32ImVec4(_REASON_COLOR)

	fitted, cut := _fit(note, right - pos.x)
	if fitted != "" do im.DrawList_AddText(dl, {pos.x, pos.y + line}, note_col, fitted)
	if cut do widgets.tooltip(strings.clone_to_cstring(note, context.temp_allocator), im.HoveredFlags_AllowWhenDisabled)
	return
}

// Draws `label` at `pos`, the ranges the terms match in the accent colour,
// and returns its width.
@(private = "file")
_draw_label :: proc(dl: ^im.DrawList, pos: im.Vec2, label: string, ts: []string) -> f32 {
	text := strings.clone_to_cstring(label, context.temp_allocator)
	plain, accent := im.GetColorU32(.Text), im.GetColorU32(.CheckMark)
	spans := make([dynamic]_Span, context.temp_allocator)
	if len(ts) > 0 do _score(label, ts, &spans)
	lit := make([]bool, len(label), context.temp_allocator)
	for sp in spans do for b in sp.lo ..< sp.hi do lit[b] = true
	raw := transmute([^]u8)text
	x := pos.x
	for start := 0; start < len(label); {
		end := start + 1
		for end < len(label) && lit[end] == lit[start] do end += 1
		lo, hi := cstring(raw[start:]), cstring(raw[end:])
		im.DrawList_AddText(dl, {x, pos.y}, accent if lit[start] else plain, lo, hi)
		x += im.CalcTextSize(lo, hi).x
		start = end
	}
	return x - pos.x
}

// `text` cut to fit `width`, with "..." when it was cut, "" when not even
// that fits. Temp.
@(private = "file")
_fit :: proc(text: string, width: f32) -> (fitted: cstring, cut: bool) {
	whole := strings.clone_to_cstring(text, context.temp_allocator)
	if im.CalcTextSize(whole).x <= width do return whole, false
	// The longest rune prefix that fits with the dots.
	lo, hi := 0, len(text)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		for mid > 0 && mid < len(text) && !utf8.rune_start(text[mid]) do mid -= 1
		if mid <= lo {
			break
		}
		try := strings.clone_to_cstring(strings.concatenate({text[:mid], "..."}, context.temp_allocator), context.temp_allocator)
		if im.CalcTextSize(try).x <= width do lo = mid
		else do hi = mid - 1
	}
	if lo == 0 do return "", true
	return strings.clone_to_cstring(strings.concatenate({strings.trim_right_space(text[:lo]), "..."}, context.temp_allocator), context.temp_allocator), true
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

// Runs a row of `mode` when it can run, and puts it first in the mode's
// recently run rows. True when it ran.
@(private = "file")
_run :: proc(mode: ^Mode, row: Row) -> bool {
	if row.disabled do return false
	if row.key != "" do _recent_push(mode.name, row.key)
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
		if c := keymap.command(m.command); c != nil && c.help != "" do widgets.tooltip(strings.clone_to_cstring(c.help, context.temp_allocator))
		im.PopID()
		im.SameLine(prefix_x)
		im.TextUnformatted(_prefix_text(m))
		im.SameLine(right - im.CalcTextSize(chords[i]).x)
		im.TextDisabled("%s", chords[i])
	}
	im.Spacing()
	im.TextDisabled("Search")
	im.TextWrapped("Terms match anywhere in a name, or as the starts of its words in order: fs and frsel find Frame Selected. The best matches come first, then the rows run recently. With nothing typed, the rows run recently come first.")
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
// whose name matches every term, or whose id contains it for a term with a
// dot, by name, with its help, the reason it cannot run and its first two
// chords.
@(private = "file")
_commands_list :: proc(query: string, rows: ^[dynamic]Row) {
	ts := terms(query)
	for cmd in keymap.commands() {
		if !keymap.in_palette(cmd) do continue
		// The name, and the id only for a term that reads as one (it has a
		// dot): ids carry package names, scene_windows, that would match
		// "window" everywhere.
		hit := true
		for term, i in ts {
			if matches(cmd.name, ts[i:i + 1]) do continue
			if strings.contains(term, ".") && contains_fold(cmd.id, term) do continue
			hit = false
			break
		}
		if !hit do continue
		enabled, reason := keymap.command_state(cmd)
		append(rows, Row{label = cmd.name, detail = _chords(cmd), help = cmd.help, disabled = !enabled, reason = reason, key = cmd.id, data = cmd})
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
