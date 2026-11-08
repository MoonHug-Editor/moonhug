package editor_tests

// The command palette's modes, headless: the case-folding match a mode tests
// every row with, the mode a text picks by its prefix, the command and chord
// a declared mode gets, the order rows are ranked in, and a command's help
// and the reason it cannot run.

import "core:slice"
import "core:testing"
import "moonhug:editor/keymap"
import "moonhug:editor/command_palette"

@(private = "file")
_pal_list :: proc(query: string, rows: ^[dynamic]command_palette.Row) {}

@(private = "file")
_pal_run :: proc(row: command_palette.Row) {}

@(private = "file")
_pal_teardown :: proc() {
	command_palette.mode_remove("T Hash")
	command_palette.mode_remove("T Hash Bang")
	command_palette.mode_remove("T Rank")
	command_palette.recent_load({})
	keymap.remove(command_palette.KEYMAP)
}

// The labels the T Rank mode lists, in this order, each keyed by itself, and
// the ones it lists disabled.
@(private = "file")
_rank_labels: []string
@(private = "file")
_rank_off: []string

@(private = "file")
_rank_list :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
	ts := command_palette.terms(query)
	for l in _rank_labels do if command_palette.matches(l, ts) {
		append(rows, command_palette.Row{label = l, key = l, disabled = slice.contains(_rank_off, l)})
	}
}

// The labels of the rows the palette shows for `text`. Temp.
@(private = "file")
_rank_order :: proc(text: string) -> []string {
	rows := command_palette.rows_for(text)
	out := make([]string, len(rows), context.temp_allocator)
	for r, i in rows do out[i] = r.label
	return out
}

@(test)
test_command_palette_match :: proc(t: ^testing.T) {
	testing.expect(t, command_palette.contains_fold("Main Camera", "camera"))
	testing.expect(t, command_palette.contains_fold("Main Camera", "n c"))
	testing.expect(t, !command_palette.contains_fold("Main Camera", "cameras"))
	testing.expect(t, command_palette.contains_fold("ÖLFASS", "öl"), "a letter outside ASCII folds too")
	testing.expect(t, command_palette.contains_fold("anything", ""))
	testing.expect(t, !command_palette.contains_fold("", "a"))
	testing.expect(t, command_palette.matches("Player Spawn", command_palette.terms("spawn PLAY")), "every term, in any order")
	testing.expect(t, !command_palette.matches("Player Spawn", command_palette.terms("spawn enemy")))

	// A term also matches as prefixes of words, in order.
	testing.expect(t, command_palette.matches("Scene/Frame Selected", {"fs"}), "initials")
	testing.expect(t, command_palette.matches("Scene/Frame Selected", {"frsel"}), "longer prefixes")
	testing.expect(t, command_palette.matches("Scene/Frame Selected", {"sfs"}), "the group's words count")
	testing.expect(t, !command_palette.matches("Frame Selected", {"sf"}), "words in order only")
	testing.expect(t, !command_palette.matches("Scene/Frame Selected", {"fsx"}))
	testing.expect(t, command_palette.matches("ShaderGraph", {"sg"}), "a capital after a lowercase letter starts a word")
	testing.expect(t, command_palette.matches("Vector3 Field", {"v3f"}), "a digit after a letter starts a word")
	testing.expect(t, command_palette.matches("player_controller.odin", {"pco"}), "punctuation separates words")
	testing.expect(t, command_palette.matches("Frame Selected", {"me sel"}), "a term with a space is a substring only")
	testing.expect(t, !command_palette.matches("Frame Selected", {"f.s"}), "a term with punctuation is a substring only")
}

@(test)
test_command_palette_rank :: proc(t: ^testing.T) {
	defer _pal_teardown()
	command_palette.mode_add("T Rank", "%", _rank_list, _pal_run, id = "t.rank")
	_rank_labels = {"Assets/Create/Physics", "Assets/Copy Path", "Frame Selected", "Fs Helper", "Refs Table", "Scene/Frame", "Select Off", "Select All", "Window/Scene"}
	_rank_off = {"Select Off"}

	order := _rank_order("%fs")
	testing.expect_value(t, len(order), 3)
	testing.expect_value(t, order[0], "Fs Helper") // a whole word at the start
	testing.expect_value(t, order[1], "Frame Selected") // prefixes of words
	testing.expect_value(t, order[2], "Refs Table") // inside a word

	order = _rank_order("%cp")
	testing.expect_value(t, order[0], "Assets/Copy Path") // prefixes of the title's words
	testing.expect_value(t, order[1], "Assets/Create/Physics") // one in the group

	order = _rank_order("%sel")
	testing.expect_value(t, order[0], "Select All") // listed after Select Off, which cannot run
	testing.expect_value(t, order[1], "Select Off") // a disabled row still outranks a worse match
	testing.expect_value(t, order[2], "Frame Selected")

	order = _rank_order("%scene")
	testing.expect_value(t, order[0], "Window/Scene") // the title outranks the group
	testing.expect_value(t, order[1], "Scene/Frame")

	// The recently run come first with no query, and break ties with one.
	command_palette.recent_load({{mode = "T Rank", keys = {"Select All", "Refs Table"}}})
	order = _rank_order("%")
	testing.expect_value(t, len(order), len(_rank_labels))
	testing.expect_value(t, order[0], "Select All")
	testing.expect_value(t, order[1], "Refs Table")
	testing.expect_value(t, order[2], "Assets/Create/Physics") // then in the mode's order
	order = _rank_order("%fs")
	testing.expect_value(t, order[0], "Fs Helper") // a better match still wins

	saved := command_palette.recent_saved()
	testing.expect_value(t, len(saved), 1)
	testing.expect_value(t, saved[0].mode, "T Rank")
	testing.expect_value(t, len(saved[0].keys), 2)
}

@(test)
test_command_palette_help_reason :: proc(t: ^testing.T) {
	keymap.command_add("T Palette/Blocked", proc() {}, enabled = proc() -> bool { return keymap.disabled("Not now") }, id = "t.blocked", help = "Does a thing")
	defer keymap.command_remove("t.blocked")
	keymap.command_add("T Palette/Off", proc() {}, enabled = proc() -> bool { return false }, id = "t.off")
	defer keymap.command_remove("t.off")

	c := keymap.command("t.blocked")
	testing.expect_value(t, c.help, "Does a thing")
	enabled, reason := keymap.command_state(c)
	testing.expect(t, !enabled)
	testing.expect_value(t, reason, "Not now")
	enabled, reason = keymap.command_state(keymap.command("t.off"))
	testing.expect(t, !enabled)
	testing.expect_value(t, reason, "") // no reason left over from the last check

	found := false
	for r in command_palette.rows_for("t palette blocked") do if r.key == "t.blocked" {
		found = true
		testing.expect_value(t, r.help, "Does a thing")
		testing.expect(t, r.disabled)
		testing.expect_value(t, r.reason, "Not now")
	}
	testing.expect(t, found, "the commands mode lists it with its help and reason")
}

@(test)
test_command_palette_mode_prefix :: proc(t: ^testing.T) {
	defer _pal_teardown()
	command_palette.mode_add("T Hash", "#", _pal_list, _pal_run, shortcut = "F9", id = "t.hash")
	command_palette.mode_add("T Hash Bang", "#!", _pal_list, _pal_run, id = "t.hash_bang")

	m, q := command_palette.mode_for("#  tex ")
	testing.expect_value(t, m.name, "T Hash")
	testing.expect_value(t, q, "tex")
	m, q = command_palette.mode_for("#!x")
	testing.expect_value(t, m.name, "T Hash Bang")
	testing.expect_value(t, q, "x")
	m, q = command_palette.mode_for("undo last")
	testing.expect_value(t, m.name, "Commands")
	testing.expect_value(t, q, "undo last")

	all := command_palette.modes()
	testing.expect_value(t, len(all), 3)
	testing.expect_value(t, all[0].name, "Commands")
}

@(test)
test_command_palette_mode_command :: proc(t: ^testing.T) {
	defer _pal_teardown()
	command_palette.mode_add("T Hash", "#", _pal_list, _pal_run, shortcut = "F9", id = "t.hash")
	c := keymap.command("Command Palette/T Hash")
	testing.expect(t, c != nil && c.id == "t.hash", "the mode gets the command Command Palette/<name> with its id")
	testing.expect_value(t, keymap.hint("t.hash"), "F9")
	testing.expect(t, keymap.find(command_palette.KEYMAP) != nil, "its chord is bound in the Command Palette Modes keymap")

	// Registered again under the same name, it replaces itself and binds once.
	command_palette.mode_add("T Hash", "#", _pal_list, _pal_run, shortcut = "F10", id = "t.hash")
	testing.expect_value(t, keymap.hint("t.hash"), "F10")
	n := 0
	for km in keymap.keymaps() do for &b in km.bindings do if keymap.binding_is(&b, "t.hash") do n += 1
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(command_palette.modes()), 2)

	command_palette.mode_remove("T Hash")
	testing.expect(t, keymap.command("t.hash") == nil, "removing the mode removes its command")
	testing.expect_value(t, len(command_palette.modes()), 1)
}
