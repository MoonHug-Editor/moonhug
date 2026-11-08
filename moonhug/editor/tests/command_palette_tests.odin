package editor_tests

// The command palette's modes, headless: the case-folding match a mode tests
// every row with, the mode a text picks by its prefix, and the command and
// chord a declared mode gets.

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
	keymap.remove(command_palette.KEYMAP)
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
