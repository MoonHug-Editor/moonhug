package editor_tests

// The keymap resolver, headless: chord parsing, the walk order (window
// keymaps before editor-wide ones, priority inside a scope), one command per
// press, a disabled command leaving its chord to the next binding, consume,
// held bindings, and the dangling-binding report. Keys come from an injected
// source, so no imgui context is needed.

import "core:testing"
import "core:os"
import "moonhug:editor"
import "moonhug:editor/handles"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"
import im "moonhug:external/odin-imgui"

@(private = "file")
_km_log: [dynamic]string
@(private = "file")
_km_path: [dynamic]string
@(private = "file")
_km_pressed: map[im.KeyChord]bool
@(private = "file")
_km_down: map[im.KeyChord]bool
@(private = "file")
_km_enabled := true
@(private = "file")
_km_typing: bool

@(private = "file")
_km_setup :: proc() {
	clear(&_km_log)
	clear(&_km_pressed)
	clear(&_km_down)
	clear(&_km_path)
	_km_enabled = true
	_km_typing = false
	keymap.focused_path = proc() -> []string { return _km_path[:] }
	keymap.key_source = {
		pressed = proc(chord: im.KeyChord, repeat: bool) -> bool { return _km_pressed[chord] },
		down    = proc(chord: im.KeyChord) -> bool { return _km_down[chord] },
		modal   = nil,
		text    = proc() -> bool { return _km_typing },
	}
}

@(private = "file")
_km_teardown :: proc() {
	for name in ([]string{"T Scene", "T Fly", "T Global", "T Low", "T Host", "T Modal", "T Early"}) do keymap.remove(name)
	for name in ([]string{"T/A", "T/B", "T/C", "T/Held"}) do keymap.command_remove(name)
	delete(_km_log)
	_km_log = nil
	delete(_km_path)
	_km_path = nil
	delete(_km_pressed)
	_km_pressed = nil
	delete(_km_down)
	_km_down = nil
}

@(private = "file")
_km_press :: proc(chord: string) {
	c, ok := keymap.parse_chord(chord)
	assert(ok)
	_km_pressed[c] = true
}

@(private = "file")
_km_hold :: proc(chord: string) {
	c, ok := keymap.parse_chord(chord)
	assert(ok)
	_km_down[c] = true
}

@(private = "file")
_km_commands :: proc() {
	keymap.command_add("T/A", proc() { append(&_km_log, "A") })
	keymap.command_add("T/B", proc() { append(&_km_log, "B") }, enabled = proc() -> bool { return _km_enabled })
	keymap.command_add("T/C", proc() { append(&_km_log, "C") })
	keymap.command_add("T/Held", proc() { append(&_km_log, "H") })
}

@(test)
test_keymap_parse_chord :: proc(t: ^testing.T) {
	chord, ok := keymap.parse_chord("Shift+Space")
	testing.expect(t, ok)
	testing.expect_value(t, chord, im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.Space))
	chord, ok = keymap.parse_chord("ctrl+shift+z")
	testing.expect(t, ok)
	testing.expect_value(t, chord, im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.Z))
	chord, ok = keymap.parse_chord("LeftShift")
	testing.expect(t, ok)
	testing.expect_value(t, chord, im.KeyChord(im.Key.LeftShift))
	chord, ok = keymap.parse_chord("F12")
	testing.expect(t, ok)
	testing.expect_value(t, chord, im.KeyChord(im.Key.F12))
	_, ok = keymap.parse_chord("Shift+Spacebar")
	testing.expect(t, !ok, "an unknown key name does not parse")
	_, ok = keymap.parse_chord("Ctrl")
	testing.expect(t, !ok, "modifiers alone are no chord")
	_, ok = keymap.parse_chord("A+B")
	testing.expect(t, !ok, "two keys are no chord")
}

// A window keymap answers only while its window is focused, and beats a
// global binding of the same chord.
@(test)
test_keymap_window_before_global :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/C") })
	keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })

	_km_press("W")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "C")

	clear(&_km_log)
	append(&_km_path, "Scene")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "A")
}

// The branch resolves innermost first: the focused view, then the view
// hosting it, then the editor-wide keymaps.
@(test)
test_keymap_host_between_view_and_global :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/C") })
	keymap.add("T Host", "Workspace", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/B") })
	keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	append(&_km_path, "Scene")
	append(&_km_path, "Workspace")
	_km_press("W")

	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "A")

	clear(&_km_log)
	keymap.remove("T Scene")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "B")
}

// A disabled command leaves its chord to the next binding. An enabled one
// takes it: a press runs one command.
@(test)
test_keymap_disabled_passes_through :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/C") })
	keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/B") })
	append(&_km_path, "Scene")
	_km_press("W")

	_km_enabled = false
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "C")

	clear(&_km_log)
	_km_enabled = true
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "B")
}

// Priority orders keymaps of one scope, and an active consuming keymap ends
// the walk, even for chords it does not bind. Held bindings run every frame
// the chord is down.
@(test)
test_keymap_priority_consume_held :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) {
		keymap.bind(km, "W", "T/A")
		keymap.bind(km, "F", "T/C")
	})
	keymap.add("T Low", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/C") }, priority = -1)
	@(static) flying: bool
	flying = false
	keymap.add("T Fly", "Scene", proc(km: ^keymap.Keymap) {
		keymap.bind(km, "W", "T/Held", held = true)
	}, active = proc() -> bool { return flying }, consume = true, priority = 10)
	append(&_km_path, "Scene")

	// Not flying: the tools keymap wins W by priority over T Low.
	_km_press("W")
	_km_press("F")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 2)
	testing.expect_value(t, _km_log[0], "A")
	testing.expect_value(t, _km_log[1], "C")

	// Flying: W held runs the held command, and F is consumed with the rest.
	clear(&_km_log)
	flying = true
	_km_hold("W")
	keymap.frame()
	keymap.frame()
	testing.expect_value(t, len(_km_log), 2)
	testing.expect_value(t, _km_log[0], "H")
	testing.expect_value(t, _km_log[1], "H")
}

// While a text field is typed in, a plain key is text and a Ctrl chord is
// still a shortcut.
@(test)
test_keymap_typing_keeps_plain_keys :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) {
		keymap.bind(km, "W", "T/A")
		keymap.bind(km, "Shift+W", "T/B")
		keymap.bind(km, "Ctrl+W", "T/C")
	})
	_km_press("W")
	_km_press("Shift+W")
	_km_press("Ctrl+W")
	_km_typing = true
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "C")
}

// A binding to a command that does not exist is inert and reported.
@(test)
test_keymap_dangling_binding :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/Missing") })
	_km_press("W")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 0)
	found := false
	for b in keymap.dangling() do if b.command == "T/Missing" do found = true
	testing.expect(t, found, "the dangling report lists the binding")
}

// An override replaces a command's chords in one keymap, survives the keymap
// being removed and registered again, round-trips through the file, and
// resets to the declared bindings.
// A shortcut lists its chords separated by a comma and a space. The comma
// key stays a chord.
@(test)
test_keymap_split_chords :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		want: []string,
	}{
		{"Ctrl+S", {"Ctrl+S"}},
		{"Ctrl+Shift+Z, Ctrl+Y", {"Ctrl+Shift+Z", "Ctrl+Y"}},
		{"Ctrl+,, F5", {"Ctrl+,", "F5"}},
		{",, `", {",", "`"}},
		{"", {}},
	}
	for c in cases {
		got := keymap.split_chords(c.text)
		testing.expect_value(t, len(got), len(c.want))
		for w, i in c.want do if i < len(got) do testing.expect_value(t, got[i], w)
	}
}

// Reset All asks first, since undo does not restore bindings: Cancel keeps
// the overrides, Reset All drops them.
@(test)
test_keymap_reset_all_asks :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	prev_path := keymap.overrides_path
	keymap.overrides_path = ""
	defer {
		widgets.dialog_close()
		keymap.override_reset_all()
		keymap.overrides_path = prev_path
	}
	km := keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	keymap.override_set(km, "T/A", {"Q"})
	testing.expect(t, keymap.has_overrides())

	editor.shortcuts_reset_all_ask()
	d, ok := widgets.dialog_current()
	testing.expect(t, ok, "the reset opens a dialog")
	testing.expect_value(t, len(d.buttons), 2)
	testing.expect(t, keymap.has_overrides(), "nothing is reset before the answer")
	widgets.dialog_choose(1)
	testing.expect(t, keymap.has_overrides(), "Cancel keeps the overrides")

	editor.shortcuts_reset_all_ask()
	widgets.dialog_choose(0)
	testing.expect(t, !keymap.has_overrides(), "Reset All drops them")
	testing.expect(t, keymap.is_default(km, "T/A"))
}

@(test)
test_keymap_override_roundtrip :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	path := "/tmp/mh_keymap_test_overrides.json"
	prev_path := keymap.overrides_path
	keymap.overrides_path = path
	defer {
		keymap.override_reset_all()
		keymap.overrides_path = prev_path
		os.remove(path)
	}
	fill := proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") }
	km := keymap.add("T Scene", "Scene", fill)
	testing.expect(t, keymap.is_default(km, "T/A"))

	keymap.override_set(km, "T/A", {"Q", "Ctrl+Q"})
	testing.expect(t, !keymap.is_default(km, "T/A"))
	testing.expect_value(t, len(km.bindings), 2)
	testing.expect_value(t, km.bindings[0].text, "Q")
	testing.expect_value(t, km.bindings[1].text, "Ctrl+Q")
	testing.expect(t, keymap.has_overrides())

	// Registered again: the override applies to the fresh keymap.
	keymap.remove("T Scene")
	km = keymap.add("T Scene", "Scene", fill)
	testing.expect_value(t, len(km.bindings), 2)
	testing.expect_value(t, km.bindings[0].text, "Q")

	// From the file.
	testing.expect(t, keymap.overrides_load())
	testing.expect_value(t, len(km.bindings), 2)
	testing.expect_value(t, km.bindings[1].text, "Ctrl+Q")

	// Reset: the declared binding is back and the file holds nothing.
	keymap.override_reset(km, "T/A")
	testing.expect(t, keymap.is_default(km, "T/A"))
	testing.expect_value(t, len(km.bindings), 1)
	testing.expect_value(t, km.bindings[0].text, "W")
	testing.expect(t, !keymap.has_overrides())
}

// A chord bound in a window's keymap and in an editor-wide one is a
// conflict the window wins. Two editor-wide keymaps settle by name.
@(test)
test_keymap_conflicts :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/C") })
	keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	keymap.add("T Low", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/B") })
	found := 0
	for cf in keymap.conflicts() {
		found += 1
		if cf.km_a.name == "T Scene" || cf.km_b.name == "T Scene" {
			testing.expect_value(t, cf.winner.command, "T/A")
		} else {
			testing.expect_value(t, cf.winner.command, "T/C")
		}
	}
	testing.expect_value(t, found, 3)
}

// The chord text round-trips through parse and back.
@(test)
test_keymap_chord_text :: proc(t: ^testing.T) {
	for text in ([]string{"Ctrl+Shift+T", "F2", "Space", "Left", "LeftShift", "Alt+["}) {
		chord, ok := keymap.parse_chord(text)
		testing.expect(t, ok, text)
		testing.expect_value(t, keymap.chord_text(chord), text)
	}
}

// A binding added after the keymap registered is a default too, as the
// menu's are, so it shows no reset and resets to itself.
@(test)
test_keymap_late_bind_is_default :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	km := keymap.add("T Global", "", nil)
	keymap.bind(km, "Ctrl+K", "T/A")
	testing.expect(t, keymap.is_default(km, "T/A"))
	testing.expect(t, !keymap.has_overrides())
	keymap.unbind(km, "T/A")
	testing.expect(t, keymap.is_default(km, "T/A"), "unbound and no default left: nothing differs")
	testing.expect_value(t, len(keymap.commands_of(km)), 0)
}

// The chord list of an override may borrow the texts of the bindings it
// replaces, as the Shortcuts page's does when it adds a chord: both survive.
@(test)
test_keymap_override_keeps_borrowed_chords :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	prev_path := keymap.overrides_path
	keymap.overrides_path = ""
	defer {
		keymap.override_reset_all()
		keymap.overrides_path = prev_path
	}
	km := keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	chords := []string{km.bindings[0].text, "Q"}
	keymap.override_set(km, "T/A", chords)
	testing.expect_value(t, len(km.bindings), 2)
	testing.expect_value(t, km.bindings[0].text, "W")
	testing.expect_value(t, km.bindings[1].text, "Q")
	// The override kept for the file is sound too: a fresh registration
	// gets the same two.
	keymap.remove("T Scene")
	km = keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	testing.expect_value(t, len(km.bindings), 2)
	testing.expect_value(t, km.bindings[0].text, "W")
	testing.expect_value(t, km.bindings[1].text, "Q")
}


// A command keeps its slot and its overrides through a rename when it has a
// stable id: the override keys by the id, and the renamed command answers
// to the new name.
@(test)
test_keymap_stable_id_survives_rename :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	prev_path := keymap.overrides_path
	keymap.overrides_path = ""
	defer {
		keymap.override_reset_all()
		keymap.overrides_path = prev_path
		keymap.command_remove("t.a")
	}
	keymap.command_add("T/A", proc() { append(&_km_log, "A") }, id = "t.a")
	km := keymap.add("T Scene", "Scene", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	keymap.override_set(km, "T/A", {"Q"})
	testing.expect(t, !keymap.is_default(km, "T/A"))

	// Renamed: same id, new name. The binding and the override follow.
	c := keymap.command_add("T/Renamed", proc() { append(&_km_log, "A") }, id = "t.a")
	testing.expect_value(t, c.name, "T/Renamed")
	testing.expect(t, keymap.command("T/A") == nil, "the old name is gone")
	testing.expect(t, keymap.command("T/Renamed") == c)
	testing.expect(t, !keymap.is_default(km, "T/Renamed"))
	testing.expect_value(t, len(keymap.commands_of(km)), 1)
	testing.expect_value(t, keymap.commands_of(km)[0], "t.a")
	append(&_km_path, "Scene")
	_km_press("Q")
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
}

// A held plain key is text while a field is typed in, like a press.
@(test)
test_keymap_typing_keeps_held_keys :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/Held", held = true) })
	_km_hold("W")
	_km_typing = true
	keymap.frame()
	testing.expect_value(t, len(_km_log), 0)
	_km_typing = false
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
}

// A binding's `mac` chord is the one on macOS, the plain chord elsewhere.
@(test)
test_keymap_mac_chord :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	km := keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "F2", "T/A", mac = "Enter") })
	when ODIN_OS == .Darwin {
		testing.expect_value(t, km.bindings[0].text, "Enter")
	} else {
		testing.expect_value(t, km.bindings[0].text, "F2")
	}
}

// A modal keymap is off until pushed, then resolves alone: the global
// binding of the same chord stays quiet, an unbound chord does nothing, and
// pop gives the keys back.
@(test)
test_keymap_modal_stack :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) {
		keymap.bind(km, "W", "T/A")
		keymap.bind(km, "F", "T/C")
	})
	modal := keymap.add("T Modal", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/Held", held = true) }, modal = true)
	_km_press("W")
	_km_hold("W")
	_km_press("F")

	keymap.frame()
	testing.expect_value(t, len(_km_log), 2)
	testing.expect_value(t, _km_log[0], "A")
	testing.expect_value(t, _km_log[1], "C")

	clear(&_km_log)
	keymap.push(modal)
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	testing.expect_value(t, _km_log[0], "H")

	clear(&_km_log)
	keymap.pop(modal)
	keymap.frame()
	testing.expect_value(t, len(_km_log), 2)
	testing.expect_value(t, len(keymap.conflicts()), 0)
}

// A keymap that names a command before the command registers: its binding
// still counts as the default once the command exists, by its name or its
// id, and a reset keeps it.
@(test)
test_keymap_default_declared_before_its_command :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	prev := keymap.overrides_path
	keymap.overrides_path = ""
	defer keymap.overrides_path = prev
	km := keymap.add("T Early", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "Ctrl+Y", "T/Redo") })
	keymap.command_add("T/Redo", proc() {}, id = "t.redo")
	defer keymap.command_remove("t.redo")
	testing.expect_value(t, keymap.commands_of(km)[0], "t.redo")
	testing.expect(t, keymap.is_default(km, "t.redo"))
	testing.expect(t, keymap.is_default(km, "T/Redo"))
	keymap.override_reset(km, "t.redo")
	testing.expect_value(t, len(km.bindings), 1)
	testing.expect_value(t, km.bindings[0].text, "Ctrl+Y")
	keymap.override_set(km, "t.redo", {"Ctrl+K"})
	testing.expect(t, !keymap.is_default(km, "T/Redo"))
	keymap.override_reset(km, "T/Redo")
	testing.expect(t, keymap.is_default(km, "t.redo"))
}

// The Shortcuts page holds the capture every frame it listens: a page that
// stops drawing gives the keys back the frame after.
@(test)
test_keymap_capture_is_held_per_frame :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) { keymap.bind(km, "W", "T/A") })
	_km_press("W")
	keymap.frame()
	keymap.capture_hold()
	keymap.frame()
	testing.expect_value(t, len(_km_log), 1)
	keymap.frame()
	testing.expect_value(t, len(_km_log), 2)
}

// The snap modifier is one command for every handle: held this frame after
// it ran, released the frame it did not.
@(test)
test_keymap_snap_is_held_per_frame :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	keymap.frame()
	testing.expect(t, !handles.snap_held())
	handles.handles_snap_hold()
	testing.expect(t, handles.snap_held())
	keymap.frame()
	testing.expect(t, !handles.snap_held())
}

// The command palette leaves out a held modifier and a command declared out of it,
// and lists the rest, bound or not.
@(test)
test_keymap_palette_listing :: proc(t: ^testing.T) {
	_km_setup()
	defer _km_teardown()
	_km_commands()
	keymap.command_add("T/Nav", proc() {}, id = "t.nav", palette = false)
	defer keymap.command_remove("t.nav")
	keymap.add("T Global", "", proc(km: ^keymap.Keymap) {
		keymap.bind(km, "W", "T/A")
		keymap.bind(km, "Q", "T/Held", held = true)
	})
	testing.expect(t, keymap.in_palette(keymap.command("T/A")))
	testing.expect(t, keymap.in_palette(keymap.command("T/C")), "an unbound command is listed")
	testing.expect(t, !keymap.in_palette(keymap.command("T/Held")), "a held modifier is not")
	testing.expect(t, !keymap.in_palette(keymap.command("t.nav")), "palette=false is not")
}
