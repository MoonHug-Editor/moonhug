package editor_tests

// The keymap resolver, headless: chord parsing, the walk order (window
// keymaps before editor-wide ones, priority inside a scope), one command per
// press, a disabled command leaving its chord to the next binding, consume,
// held bindings, and the dangling-binding report. Keys come from an injected
// source, so no imgui context is needed.

import "core:testing"
import "moonhug:editor/keymap"
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
_km_setup :: proc() {
	clear(&_km_log)
	clear(&_km_pressed)
	clear(&_km_down)
	clear(&_km_path)
	_km_enabled = true
	keymap.focused_path = proc() -> []string { return _km_path[:] }
	keymap.key_source = {
		pressed = proc(chord: im.KeyChord, repeat: bool) -> bool { return _km_pressed[chord] },
		down    = proc(chord: im.KeyChord) -> bool { return _km_down[chord] },
		modal   = nil,
	}
}

@(private = "file")
_km_teardown :: proc() {
	for name in ([]string{"T Scene", "T Fly", "T Global", "T Low", "T Host"}) do keymap.remove(name)
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
