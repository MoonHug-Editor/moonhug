package keymap

// Editor commands and keymaps (docs/core/Keymaps.md).
//
// A command is a named proc the editor can run from a key, a menu, a
// palette or the bridge. A keymap binds chords to command names, serves one
// window or the whole editor, and is active by a rule. Every frame the
// resolver walks the active keymaps, most specific first, and runs the
// command of the first binding whose chord is pressed and whose command is
// enabled. Views read no keys themselves.
//
// Key source: imgui's events. A press goes through im.Shortcut with global
// routing, so a text field, an open dialog or any other key owner wins as it
// does for a menu shortcut. A held binding reads the key's down state every
// frame, for a tool that moves while a key is held (the scene flythrough).
//
// Order and ownership, every frame:
// - no resolution while a modal popup is open
// - the keymaps of the focused view, by priority, highest first
// - then the keymaps of the view hosting it, the same way
// - then the keymaps with no window, by priority, highest first
// - one press runs one command: a chord a command took is done for the frame
// - a disabled command does not take its chord: the next binding may
// - a keymap with `consume` ends the walk after itself, even for chords it
//   does not bind (the flythrough owns every key while it flies)
// - while a text field is being typed in, only chords with Ctrl, Alt or
//   Super resolve: a plain key or a Shift chord is text
//
// The focused branch comes through `focused_path`, which the shell installs
// from the window registry: the focused view, then the view hosting it (a
// Workspace view), innermost first. There is no hover focus: a key goes to
// the clicked view. A setting may later swap the source for the hovered
// view's branch, which is the whole of Blender's model.
//
// Registries pin the default allocator: declarations register at startup and
// live for the session.

import "base:runtime"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"

// A command the editor can run. `run` takes no data, `run_data` takes `data`:
// a registration sets one of them. `enabled` and `enabled_data` the same way,
// nil for always enabled.
Command :: struct {
	name:         string, // "Edit/Undo", "Scene/Translate Tool": a group, a slash, spaced words. Owned
	run:          proc(),
	enabled:      proc() -> bool,
	run_data:     proc(data: rawptr),
	enabled_data: proc(data: rawptr) -> bool,
	data:         rawptr,
	origin:       string, // where it was declared, for the Shortcuts window and Debug Tooltips
}

// One chord bound to a command name.
Binding :: struct {
	chord:   im.KeyChord,
	text:    string, // the chord as declared ("Ctrl+S"), for display. Owned
	command: string, // the command's name. Owned
	// Runs the command every frame while the chord is down instead of once
	// on the press. The chord's modifiers may be a subset of the ones held,
	// so a plain key keeps working while a modifier is also held.
	held:    bool,
	// The press repeats while the key stays down (arrow keys in a list).
	repeat:  bool,
	cmd:     ^Command, // resolved on use, nil until the command exists
}

// A keymap: a named set of bindings with an activation rule.
Keymap :: struct {
	name:     string, // "Scene Tools": spaced words. Owned
	window:   string, // the window id it serves, "" for the whole editor. Owned
	active:   proc() -> bool, // nil: active whenever its window is focused, or always for a window-less one
	consume:  bool, // ends the walk after this keymap while active
	priority: int, // higher resolves first among keymaps of the same scope
	bindings: [dynamic]Binding,
	origin:   string,
}

@(private = "file")
_commands: [dynamic]^Command
@(private = "file")
_keymaps: [dynamic]^Keymap

// The ids of the focused branch, innermost first: the focused view's window,
// then its host's, empty for none. The shell installs it from the window
// registry; tests set it directly. Temp.
focused_path: proc() -> []string

// Where the key state comes from. imgui by default; tests inject frames.
Key_Source :: struct {
	pressed: proc(chord: im.KeyChord, repeat: bool) -> bool,
	down:    proc(chord: im.KeyChord) -> bool,
	// Whether a modal popup owns the frame: nothing resolves then.
	modal:   proc() -> bool,
	// Whether a text field is being typed in: plain chords are text then.
	text:    proc() -> bool,
}

key_source := Key_Source{
	pressed = _imgui_pressed,
	down    = _imgui_down,
	modal   = _imgui_modal,
	text    = _imgui_text,
}

// The modifiers that make a chord a shortcut while typing.
@(private = "file")
_COMMAND_MODS :: im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.ImGuiMod_Alt) | im.KeyChord(im.Key.ImGuiMod_Super)

// Registers a command, replacing one of the same name. A command declared
// with `@(command)` on a proc that takes nothing registers here through the
// generated _register_editor_keymaps. `name` is "Group/Title", the group
// being the window or feature it belongs to. `enabled` names a proc that
// says whether the command can run now: a disabled command leaves its key to
// the next binding.
@(extension_point={attribute="command", target="proc", fields="name enabled"})
command_add :: proc(name: string, run: proc(), enabled: proc() -> bool = nil, origin := "") -> ^Command {
	c := _command_slot(name)
	c.run = run
	c.enabled = enabled
	c.run_data = nil
	c.enabled_data = nil
	c.data = nil
	c.origin = origin
	return c
}

// A command that closes over data (a menu item's node).
command_add_data :: proc(name: string, run: proc(data: rawptr), data: rawptr, enabled: proc(data: rawptr) -> bool = nil, origin := "") -> ^Command {
	c := _command_slot(name)
	c.run = nil
	c.enabled = nil
	c.run_data = run
	c.enabled_data = enabled
	c.data = data
	c.origin = origin
	return c
}

@(private = "file")
_command_slot :: proc(name: string) -> ^Command {
	context.allocator = runtime.default_allocator()
	if c := command(name); c != nil do return c
	c := new(Command)
	c.name = strings.clone(name)
	append(&_commands, c)
	return c
}

// The command named `name`, nil when none.
command :: proc(name: string) -> ^Command {
	for c in _commands do if c.name == name do return c
	return nil
}

// Every command, in registration order.
commands :: proc() -> []^Command {
	return _commands[:]
}

// Whether a command can run now.
command_enabled :: proc(c: ^Command) -> bool {
	if c.enabled != nil do return c.enabled()
	if c.enabled_data != nil do return c.enabled_data(c.data)
	return true
}

// Runs a command, enabled or not: the caller checked.
command_run :: proc(c: ^Command) {
	if c.run != nil do c.run()
	else if c.run_data != nil do c.run_data(c.data)
}

// Runs the command named `name` when it exists and is enabled. True when it
// ran.
run :: proc(name: string) -> bool {
	c := command(name)
	if c == nil || !command_enabled(c) do return false
	command_run(c)
	return true
}

// Declares a keymap and fills it: `fill` binds its chords (bind). A keymap
// declared with `@(keymap)` on a proc taking `^Keymap` registers here through
// the generated _register_editor_keymaps. `window` is the id of the window it
// serves, "" for the whole editor. `active` names a proc that says whether
// the keymap resolves this frame, on top of its window being focused. A
// keymap with `consume` ends resolution after itself while active. `priority`
// orders keymaps of the same scope, highest first.
@(extension_point={attribute="keymap", target="proc", fields="name window active consume priority"})
add :: proc(name: string, window: string, fill: proc(km: ^Keymap), active: proc() -> bool = nil, consume := false, priority := 0, origin := "") -> ^Keymap {
	context.allocator = runtime.default_allocator()
	km := find(name)
	if km == nil {
		km = new(Keymap)
		km.name = strings.clone(name)
		append(&_keymaps, km)
	} else {
		delete(km.window)
		clear_bindings(km)
	}
	km.window = strings.clone(window)
	km.active = active
	km.consume = consume
	km.priority = priority
	km.origin = origin
	if fill != nil do fill(km)
	_sort()
	return km
}

// The keymap named `name`, nil when none.
find :: proc(name: string) -> ^Keymap {
	for km in _keymaps do if km.name == name do return km
	return nil
}

// Every keymap, in resolution order.
keymaps :: proc() -> []^Keymap {
	return _keymaps[:]
}

// Binds `chord` ("Ctrl+S", "W", "Shift+Space", "LeftShift") to the command
// named `command` in `km`. A chord that does not parse is a declaration
// error: it panics with the keymap's origin.
bind :: proc(km: ^Keymap, chord: string, command: string, held := false, repeat := false) {
	context.allocator = runtime.default_allocator()
	parsed, ok := parse_chord(chord)
	if !ok {
		panic(strings.concatenate({"keymap ", km.name, ": chord \"", chord, "\" for ", command, " does not parse  ", km.origin}, context.temp_allocator))
	}
	append(&km.bindings, Binding{
		chord   = parsed,
		text    = strings.clone(chord),
		command = strings.clone(command),
		held    = held,
		repeat  = repeat,
	})
}

// Drops the binding of `command` in `km`, if any.
unbind :: proc(km: ^Keymap, command: string) {
	context.allocator = runtime.default_allocator()
	for b, i in km.bindings do if b.command == command {
		delete(b.text)
		delete(b.command)
		ordered_remove(&km.bindings, i)
		return
	}
}

// Drops every binding of `km`.
clear_bindings :: proc(km: ^Keymap) {
	context.allocator = runtime.default_allocator()
	for b in km.bindings {
		delete(b.text)
		delete(b.command)
	}
	clear(&km.bindings)
}

// Removes a keymap. For tests.
remove :: proc(name: string) {
	context.allocator = runtime.default_allocator()
	for km, i in _keymaps do if km.name == name {
		_free_keymap(km)
		ordered_remove(&_keymaps, i)
		return
	}
}

@(private = "file")
_free_keymap :: proc(km: ^Keymap) {
	context.allocator = runtime.default_allocator()
	clear_bindings(km)
	delete(km.bindings)
	delete(km.name)
	delete(km.window)
	free(km)
}

// Removes a command. For tests.
command_remove :: proc(name: string) {
	context.allocator = runtime.default_allocator()
	for c, i in _commands do if c.name == name {
		for km in _keymaps do for &b in km.bindings do if b.cmd == c do b.cmd = nil
		delete(c.name)
		free(c)
		ordered_remove(&_commands, i)
		return
	}
}

// Keymaps of the same scope resolve by priority, highest first, then by
// name, so the order is the same whatever the registration order.
@(private = "file")
_sort :: proc() {
	slice.sort_by(_keymaps[:], proc(a, b: ^Keymap) -> bool {
		if a.priority != b.priority do return a.priority > b.priority
		return a.name < b.name
	})
}

// The bindings whose command does not exist, for the Shortcuts window and
// the contract test. Temp.
dangling :: proc(allocator := context.temp_allocator) -> []^Binding {
	out := make([dynamic]^Binding, allocator)
	for km in _keymaps do for &b in km.bindings {
		if _resolve(&b) == nil do append(&out, &b)
	}
	return out[:]
}

@(private = "file")
_resolve :: proc(b: ^Binding) -> ^Command {
	if b.cmd == nil do b.cmd = command(b.command)
	return b.cmd
}

// Resolves this frame's keys. Called once per frame from the main loop after
// the imgui frame starts and before the views draw, so a command's effect
// shows the same frame.
frame :: proc() {
	if key_source.modal != nil && key_source.modal() do return
	path := focused_path() if focused_path != nil else nil
	typing := key_source.text != nil && key_source.text()
	taken := make(map[im.KeyChord]bool, context.temp_allocator)
	// Innermost level first, the editor-wide keymaps last: a view's binding
	// beats its host's, which beats a global one, for the same chord.
	for level in 0 ..= len(path) {
		id := path[level] if level < len(path) else ""
		for km in _keymaps {
			if km.window != id do continue
			if km.active != nil && !km.active() do continue
			for &b in km.bindings {
				if typing && b.chord & _COMMAND_MODS == 0 do continue
				if b.held {
					if !key_source.down(b.chord) do continue
				} else {
					if b.chord in taken do continue
					if !key_source.pressed(b.chord, b.repeat) do continue
				}
				c := _resolve(&b)
				if c == nil || !command_enabled(c) do continue
				command_run(c)
				if !b.held do taken[b.chord] = true
			}
			if km.consume do return
		}
	}
}

// Frees every registration.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for km in _keymaps do _free_keymap(km)
	delete(_keymaps)
	_keymaps = nil
	for c in _commands {
		delete(c.name)
		free(c)
	}
	delete(_commands)
	_commands = nil
}

// --- imgui key source -------------------------------------------------------

@(private = "file")
_imgui_pressed :: proc(chord: im.KeyChord, repeat: bool) -> bool {
	flags: im.InputFlags = {.RouteGlobal}
	if repeat do flags += {.Repeat}
	return im.Shortcut(chord, flags)
}

// Down with the chord's modifiers held, more allowed: the walk already
// ordered the keymaps, so a held plain key need not refuse a modifier.
@(private = "file")
_imgui_down :: proc(chord: im.KeyChord) -> bool {
	mods := chord & im.KeyChord(im.Key.ImGuiMod_Mask_)
	key := im.Key(chord & ~im.KeyChord(im.Key.ImGuiMod_Mask_))
	if im.GetIO().KeyMods & mods != mods do return false
	return im.IsKeyDown(key)
}

@(private = "file")
_imgui_modal :: proc() -> bool {
	return im.GetTopMostPopupModal() != nil
}

@(private = "file")
_imgui_text :: proc() -> bool {
	return im.GetIO().WantTextInput
}

// --- chords -----------------------------------------------------------------

// Parses "Ctrl+S", "Shift+Space", "F2", "Escape", "LeftShift" into an imgui
// chord. Modifiers: Ctrl (Cmd on macOS), Shift, Alt, Super. Keys: letters,
// digits, F1 to F12, the named keys below, and , . - = / [ ] ; ' \ ` as the
// character. Case does not matter.
parse_chord :: proc(text: string) -> (chord: im.KeyChord, ok: bool) {
	s := strings.trim_space(text)
	if s == "" do return 0, false
	parts := strings.split(s, "+", context.temp_allocator)
	mods: im.KeyChord
	key: im.Key = .None
	for p in parts {
		tok := strings.trim_space(p)
		if tok == "" do continue
		lower := strings.to_lower(tok, context.temp_allocator)
		switch lower {
		case "ctrl", "control": mods |= im.KeyChord(im.Key.ImGuiMod_Ctrl)
		case "alt", "option":   mods |= im.KeyChord(im.Key.ImGuiMod_Alt)
		case "shift":           mods |= im.KeyChord(im.Key.ImGuiMod_Shift)
		case "super", "cmd":    mods |= im.KeyChord(im.Key.ImGuiMod_Super)
		case:
			k, known := parse_key(lower)
			if !known || key != .None do return 0, false
			key = k
		}
	}
	if key == .None do return 0, false
	return mods | im.KeyChord(key), true
}

// One key name, lower case, as parse_chord accepts it.
parse_key :: proc(lower: string) -> (key: im.Key, ok: bool) {
	if len(lower) == 1 {
		r := lower[0]
		switch {
		case r >= 'a' && r <= 'z': return im.Key(int(im.Key.A) + int(r - 'a')), true
		case r >= '0' && r <= '9': return im.Key(int(im.Key._0) + int(r - '0')), true
		}
		switch r {
		case ',':  return .Comma, true
		case '.':  return .Period, true
		case '-':  return .Minus, true
		case '=':  return .Equal, true
		case '/':  return .Slash, true
		case '[':  return .LeftBracket, true
		case ']':  return .RightBracket, true
		case ';':  return .Semicolon, true
		case '\'': return .Apostrophe, true
		case '\\': return .Backslash, true
		case '`':  return .GraveAccent, true
		}
		return .None, false
	}
	if lower[0] == 'f' {
		n := 0
		digits := true
		for i in 1 ..< len(lower) {
			if lower[i] < '0' || lower[i] > '9' {
				digits = false
				break
			}
			n = n * 10 + int(lower[i] - '0')
		}
		if digits && n >= 1 && n <= 12 do return im.Key(int(im.Key.F1) + n - 1), true
	}
	switch lower {
	case "space":                 return .Space, true
	case "escape", "esc":         return .Escape, true
	case "enter", "return":       return .Enter, true
	case "tab":                   return .Tab, true
	case "backspace":             return .Backspace, true
	case "delete", "del":         return .Delete, true
	case "insert":                return .Insert, true
	case "home":                  return .Home, true
	case "end":                   return .End, true
	case "pageup":                return .PageUp, true
	case "pagedown":              return .PageDown, true
	case "left":                  return .LeftArrow, true
	case "right":                 return .RightArrow, true
	case "up":                    return .UpArrow, true
	case "down":                  return .DownArrow, true
	case "leftshift":             return .LeftShift, true
	case "rightshift":            return .RightShift, true
	case "leftctrl":              return .LeftCtrl, true
	case "rightctrl":             return .RightCtrl, true
	case "leftalt":               return .LeftAlt, true
	case "rightalt":              return .RightAlt, true
	}
	return .None, false
}
