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
//   does not bind
// - a modal keymap, pushed by the tool that runs it (push, pop), is the only
//   one that resolves while it is on top: the flythrough's keys while the
//   camera flies. It takes every key, bound or not.
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
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:libs/log"

// A command the editor can run. `run` takes no data, `run_data` takes `data`:
// a registration sets one of them. `enabled` and `enabled_data` the same way,
// nil for always enabled.
Command :: struct {
	// The stable identity bindings and the override file refer to: the
	// declaring proc's qualified name ("editor.scene_tool_translate") unless
	// the declaration gives one. A command keeps its id through a rename or
	// a menu move, so the user's bindings follow. Owned
	id:           string,
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
	// A tool's keymap: off until the tool pushes it, then the only one that
	// resolves, until the tool pops it. No window, no rule, no priority.
	modal:    bool,
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
// `id` is the stable identity, the proc's qualified name by default: give
// one to keep the user's bindings through a rename of the proc.
@(extension_point={attribute="command", target="proc", fields="name enabled id"})
command_add :: proc(name: string, run: proc(), enabled: proc() -> bool = nil, origin := "", id := "") -> ^Command {
	c := _command_slot(name, id)
	c.run = run
	c.enabled = enabled
	c.run_data = nil
	c.enabled_data = nil
	c.data = nil
	c.origin = origin
	return c
}

// A command that closes over data (a menu item's node).
command_add_data :: proc(name: string, run: proc(data: rawptr), data: rawptr, enabled: proc(data: rawptr) -> bool = nil, origin := "", id := "") -> ^Command {
	c := _command_slot(name, id)
	c.run = nil
	c.enabled = nil
	c.run_data = run
	c.enabled_data = enabled
	c.data = data
	c.origin = origin
	return c
}

// The slot for a command: the one with its id, which keeps the slot through
// a rename, else the one with its name, else a new one. An empty id is the
// name.
@(private = "file")
_command_slot :: proc(name: string, id: string) -> ^Command {
	context.allocator = runtime.default_allocator()
	id := id if id != "" else name
	c: ^Command
	for e in _commands do if e.id == id {
		c = e
		break
	}
	if c == nil do for e in _commands do if e.name == name {
		c = e
		break
	}
	if c == nil {
		c = new(Command)
		append(&_commands, c)
	}
	if c.name != name {
		delete(c.name)
		c.name = strings.clone(name)
	}
	if c.id != id {
		delete(c.id)
		c.id = strings.clone(id)
	}
	return c
}

// The command with the id `key`, else the one named `key`, nil when none.
command :: proc(key: string) -> ^Command {
	for c in _commands do if c.id == key do return c
	for c in _commands do if c.name == key do return c
	return nil
}

// The stable key for `key`, a command's id or name: its id when the command
// exists, else `key` as given.
@(private = "file")
_canonical :: proc(key: string) -> string {
	if c := command(key); c != nil do return c.id
	return key
}

// Whether `b` binds the command `key` names, by id or by name.
binding_is :: proc(b: ^Binding, key: string) -> bool {
	return b.command == key || _canonical(b.command) == _canonical(key)
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
// A keymap with `modal` is a tool's: it resolves only while the tool holds
// it pushed, and then alone.
@(extension_point={attribute="keymap", target="proc", fields="name window active consume priority modal"})
add :: proc(name: string, window: string, fill: proc(km: ^Keymap), active: proc() -> bool = nil, consume := false, priority := 0, origin := "", modal := false) -> ^Keymap {
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
	km.modal = modal
	km.priority = priority
	km.origin = origin
	_defaults_drop(km.name)
	if fill != nil do fill(km)
	_overrides_apply(km)
	_sort()
	// A keymap registered after startup, a view's at runtime: its conflicts
	// are logged now, the startup ones went out with log_conflicts.
	if _started do log_conflicts(km)
	return km
}

@(private = "file")
_started: bool

// Logs every conflict with the resolver's verdict, once at startup after the
// overrides loaded, and marks startup done so a keymap registered later logs
// its own (add). With `only`, the conflicts involving that keymap.
log_conflicts :: proc(only: ^Keymap = nil) {
	_started = true
	for cf in conflicts() {
		if only != nil && cf.km_a != only && cf.km_b != only do continue
		winner := cf.km_a if cf.winner == cf.a else cf.km_b
		log.warningf("keymap: %s binds %s in %s and %s does in %s: %s wins, %s", cf.a.command, cf.a.text, cf.km_a.name, cf.b.command, cf.km_b.name, winner.name, cf.why)
	}
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
// named `command` in `km`. `mac` is the chord on macOS when it differs, so
// a platform's default is data beside the other's, as a keybinding rule
// with a `mac` field is: the Project view opens on Enter and on Cmd+Down
// there. A chord that does not parse is a declaration error: it panics
// with the keymap's origin.
bind :: proc(km: ^Keymap, chord: string, command: string, held := false, repeat := false, mac := "") {
	context.allocator = runtime.default_allocator()
	chord := chord
	when ODIN_OS == .Darwin do if mac != "" do chord = mac
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
	// The declaration is the default, also for a keymap bound after it
	// registered (the menu's). An override on file for the command replaces
	// it at once.
	ckey := _canonical(command)
	key := _default_key(km.name, ckey)
	ds, known := &_defaults[key]
	if !known {
		_defaults[strings.clone(key)] = {}
		ds = &_defaults[key]
	}
	append(ds, _Default{text = strings.clone(chord), held = held, repeat = repeat})
	if cmds, has := _overrides[km.name]; has {
		if chords, over := cmds[ckey]; over do _override_apply(km, ckey, chords[:])
		else if chords, over2 := cmds[command]; over2 do _override_apply(km, ckey, chords[:])
	}
}

// Drops the binding of `command` in `km`, if any.
unbind :: proc(km: ^Keymap, command: string) {
	context.allocator = runtime.default_allocator()
	key := _default_key(km.name, _canonical(command))
	if ds, ok := _defaults[key]; ok {
		_default_free(ds)
		dk, _ := delete_key(&_defaults, key)
		delete(dk)
	}
	for i := len(km.bindings) - 1; i >= 0; i -= 1 {
		if !binding_is(&km.bindings[i], command) do continue
		delete(km.bindings[i].text)
		delete(km.bindings[i].command)
		ordered_remove(&km.bindings, i)
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
		pop(km)
		_defaults_drop(name)
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
	for c, i in _commands do if c.name == name || c.id == name {
		for km in _keymaps do for &b in km.bindings do if b.cmd == c do b.cmd = nil
		delete(c.name)
		delete(c.id)
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
	if capturing do return
	if key_source.modal != nil && key_source.modal() do return
	path := focused_path() if focused_path != nil else nil
	typing := key_source.text != nil && key_source.text()
	taken := make(map[im.KeyChord]bool, context.temp_allocator)
	// A tool's keymap on top of the modal stack resolves alone.
	if top := modal_top(); top != nil {
		_resolve_keymap(top, typing, &taken)
		return
	}
	// Innermost level first, the editor-wide keymaps last: a view's binding
	// beats its host's, which beats a global one, for the same chord.
	for level in 0 ..= len(path) {
		id := path[level] if level < len(path) else ""
		for km in _keymaps {
			if km.modal || km.window != id do continue
			if km.active != nil && !km.active() do continue
			_resolve_keymap(km, typing, &taken)
			if km.consume do return
		}
	}
}

// Runs the commands of `km`'s bindings whose chord is pressed or held this
// frame. `taken` holds the chords a command already took.
@(private = "file")
_resolve_keymap :: proc(km: ^Keymap, typing: bool, taken: ^map[im.KeyChord]bool) {
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
}

// --- Modal stack ---------------------------------------------------------------

@(private = "file")
_modal: [dynamic]^Keymap

// Puts a tool's keymap on top: it alone resolves until pop. Pushing a keymap
// already on the stack moves it to the top.
push :: proc(km: ^Keymap) {
	context.allocator = runtime.default_allocator()
	pop(km)
	append(&_modal, km)
}

// Takes a tool's keymap off the stack, wherever it is. Nothing when it is
// not on it.
pop :: proc(km: ^Keymap) {
	for e, i in _modal do if e == km {
		ordered_remove(&_modal, i)
		return
	}
}

// The keymap on top of the modal stack, nil when no tool holds one.
modal_top :: proc() -> ^Keymap {
	if len(_modal) == 0 do return nil
	return _modal[len(_modal) - 1]
}

// Frees every registration.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for k, ds in _defaults {
		_default_free(ds)
		delete(k)
	}
	delete(_defaults)
	_defaults = nil
	_overrides_clear()
	delete(_overrides)
	_overrides = nil
	for km in _keymaps do _free_keymap(km)
	delete(_keymaps)
	_keymaps = nil
	delete(_modal)
	_modal = nil
	for c in _commands {
		delete(c.name)
		delete(c.id)
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

// --- Defaults and overrides ---------------------------------------------------
//
// The bindings a keymap declares are its defaults, recorded as they bind.
// A user's override replaces the chord list of one command in one keymap,
// and one file holds every override by keymap name and command id, with
// nothing else, defaults stay in code: shortcuts.json under the OS user's
// config folder, machine-wide, since shortcuts are the developer's, not the
// project's. An override for a keymap that is not registered stays in the
// file and applies the moment that keymap registers, so a plugin turned off
// and on, or a view that registers its keymap at runtime, keeps the user's
// bindings.

// One command's default bindings, kept for reset and for the chord list of
// a reset binding.
@(private = "file")
_Default :: struct {
	text:   string, // owned
	held:   bool,
	repeat: bool,
}

@(private = "file")
_defaults: map[string][dynamic]_Default // "<keymap>\x00<command>" -> its default bindings

// The override file as loaded and edited: keymap -> command -> chord texts.
// Owned strings.
@(private = "file")
_overrides: map[string]map[string][dynamic]string

@(private = "file")
_default_key :: proc(km, command: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({km, "\x00", command}, allocator)
}

// Drops the defaults recorded for a keymap: it registers again.
@(private = "file")
_defaults_drop :: proc(name: string) {
	context.allocator = runtime.default_allocator()
	for k, ds in _defaults do if strings.has_prefix(k, name) && len(k) > len(name) && k[len(name)] == 0 {
		_default_free(ds)
		dk, _ := delete_key(&_defaults, k)
		delete(dk)
	}
}

// Applies the overrides on file for `km`.
@(private = "file")
_overrides_apply :: proc(km: ^Keymap) {
	if cmds, ok := _overrides[km.name]; ok {
		for command, chords in cmds do _override_apply(km, _canonical(command), chords[:])
	}
}

@(private = "file")
_default_free :: proc(ds: [dynamic]_Default) {
	for d in ds do delete(d.text)
	delete(ds)
}

// Whether `command`'s bindings in `km` are its defaults.
is_default :: proc(km: ^Keymap, command: string) -> bool {
	ds := _defaults[_default_key(km.name, _canonical(command))] or_else nil
	n := 0
	for &b in km.bindings do if binding_is(&b, command) {
		if n >= len(ds) || ds[n].text != b.text do return false
		n += 1
	}
	return n == len(ds)
}

// The commands `km` binds by default or by override, each once by its
// stable key, in the order they first appear. Temp.
commands_of :: proc(km: ^Keymap, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	seen := make(map[string]bool, allocator)
	for b in km.bindings {
		key := _canonical(b.command)
		if key in seen do continue
		seen[key] = true
		append(&out, key)
	}
	for k in _defaults do if strings.has_prefix(k, km.name) && len(k) > len(km.name) && k[len(km.name)] == 0 {
		command := k[len(km.name) + 1:]
		if command not_in seen {
			seen[command] = true
			append(&out, command)
		}
	}
	return out[:]
}

// Replaces the bindings of `command` in `km` with `chords`, keeps the
// override in the file's map, and writes the file. An empty list unbinds
// the command. The held and repeat flags come from the command's first
// default binding.
override_set :: proc(km: ^Keymap, command: string, chords: []string) {
	context.allocator = runtime.default_allocator()
	// The list may borrow the texts of the bindings about to go (the
	// Shortcuts page builds it from them): copy it first.
	chords := slice.clone(chords, context.temp_allocator)
	for &c in chords do c = strings.clone(c, context.temp_allocator)
	command := _canonical(command)
	_override_apply(km, command, chords)
	cmds, ok := &_overrides[km.name]
	if !ok {
		_overrides[strings.clone(km.name)] = {}
		cmds = &_overrides[km.name]
	}
	if old, had := cmds[command]; had {
		for c in old do delete(c)
		delete(old)
		ck, _ := delete_key(cmds, command)
		delete(ck)
	}
	list: [dynamic]string
	for c in chords do append(&list, strings.clone(c))
	cmds[strings.clone(command)] = list
	overrides_save()
}

// Puts `command`'s default bindings back in `km` and drops its override.
override_reset :: proc(km: ^Keymap, command: string) {
	context.allocator = runtime.default_allocator()
	command := _canonical(command)
	if cmds, ok := &_overrides[km.name]; ok {
		if old, had := cmds[command]; had {
			for c in old do delete(c)
			delete(old)
			ck, _ := delete_key(cmds, command)
			delete(ck)
		}
		if len(cmds) == 0 {
			delete(cmds^)
			kk, _ := delete_key(&_overrides, km.name)
			delete(kk)
		}
	}
	ds := _defaults[_default_key(km.name, command)] or_else nil
	texts := make([]string, len(ds), context.temp_allocator)
	for d, i in ds do texts[i] = d.text
	_override_apply(km, command, texts)
	overrides_save()
}

// Resets every command of `km`.
override_reset_keymap :: proc(km: ^Keymap) {
	for command in commands_of(km) do override_reset(km, command)
}

// Resets every keymap.
override_reset_all :: proc() {
	for km in _keymaps do override_reset_keymap(km)
}

// Whether any override is in effect or on file.
has_overrides :: proc() -> bool {
	return len(_overrides) > 0
}

@(private = "file")
_override_apply :: proc(km: ^Keymap, command: string, chords: []string) {
	context.allocator = runtime.default_allocator()
	held, repeat := false, false
	if ds := _defaults[_default_key(km.name, command)] or_else nil; len(ds) > 0 {
		held, repeat = ds[0].held, ds[0].repeat
	}
	for i := len(km.bindings) - 1; i >= 0; i -= 1 {
		if !binding_is(&km.bindings[i], command) do continue
		delete(km.bindings[i].text)
		delete(km.bindings[i].command)
		ordered_remove(&km.bindings, i)
	}
	for c in chords {
		parsed, ok := parse_chord(c)
		if !ok do continue
		append(&km.bindings, Binding{chord = parsed, text = strings.clone(c), command = strings.clone(command), held = held, repeat = repeat})
	}
}

// The file the overrides live in, set by the shell before overrides_load.
overrides_path: string

// Reads the override file and applies it to the registered keymaps. A
// missing file is no overrides.
overrides_load :: proc() -> bool {
	context.allocator = runtime.default_allocator()
	_overrides_clear()
	if overrides_path == "" do return false
	data, rerr := os.read_entire_file(overrides_path, context.temp_allocator)
	if rerr != nil do return false
	root, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil do return false
	obj, is_obj := root.(json.Object)
	if !is_obj do return false
	for km_name, cmds_v in obj {
		cmds, ok2 := cmds_v.(json.Object)
		if !ok2 do continue
		list: map[string][dynamic]string
		for command, chords_v in cmds {
			chords, ok3 := chords_v.(json.Array)
			if !ok3 do continue
			texts: [dynamic]string
			for c in chords do if s, is_s := c.(json.String); is_s do append(&texts, strings.clone(s))
			list[strings.clone(command)] = texts
		}
		_overrides[strings.clone(km_name)] = list
	}
	for km in _keymaps do _overrides_apply(km)
	return true
}

// Writes every override, the ones of keymaps that are not registered
// included. Keymap and command names sorted, so the file diffs well.
overrides_save :: proc() -> bool {
	if overrides_path == "" do return false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n")
	names := make([dynamic]string, context.temp_allocator)
	for k in _overrides do append(&names, k)
	slice.sort(names[:])
	for name, ni in names {
		cmds := _overrides[name]
		fmt.sbprintf(&b, "\t%q: {{\n", name)
		cnames := make([dynamic]string, context.temp_allocator)
		for c in cmds do append(&cnames, c)
		slice.sort(cnames[:])
		for cname, ci in cnames {
			fmt.sbprintf(&b, "\t\t%q: [", cname)
			for chord, i in cmds[cname] {
				if i > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "%q", chord)
			}
			strings.write_string(&b, "]")
			strings.write_string(&b, ",\n" if ci + 1 < len(cnames) else "\n")
		}
		strings.write_string(&b, "\t}")
		strings.write_string(&b, ",\n" if ni + 1 < len(names) else "\n")
	}
	strings.write_string(&b, "}\n")
	if dir := filepath.dir(overrides_path); dir != "" do os.make_directory_all(dir)
	return os.write_entire_file(overrides_path, transmute([]u8)strings.to_string(b)) == nil
}

@(private = "file")
_overrides_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for k, cmds in _overrides {
		for c, chords in cmds {
			for s in chords do delete(s)
			delete(chords)
			delete(c)
		}
		delete(cmds)
		delete(k)
	}
	clear(&_overrides)
}

// --- Conflicts ----------------------------------------------------------------

// Two bindings one chord can reach in the same frame: the keymaps serve the
// same window, or one of them serves the whole editor. `winner` is the one
// the resolver runs, by the walk order (the window's keymap, then priority,
// then name), and `why` says so in words for the Shortcuts page.
Conflict :: struct {
	a, b:       ^Binding,
	km_a, km_b: ^Keymap,
	winner:     ^Binding,
	why:        string, // temp
}

conflicts :: proc(allocator := context.temp_allocator) -> []Conflict {
	out := make([dynamic]Conflict, allocator)
	for ka, i in _keymaps do for kb in _keymaps[i + 1:] {
		// A modal keymap resolves alone: nothing conflicts with it.
		if ka.modal || kb.modal do continue
		if ka.window != "" && kb.window != "" && ka.window != kb.window do continue
		for &a in ka.bindings do for &b in kb.bindings {
			if a.chord != b.chord || a.held != b.held do continue
			c := Conflict{a = &a, b = &b, km_a = ka, km_b = kb}
			switch {
			case ka.window != kb.window:
				// The window's keymap beats the editor-wide one. Both
				// cannot be "" here, so one serves a window.
				if ka.window != "" { c.winner = &a } else { c.winner = &b }
				c.why = fmt.tprintf("%s wins: a window's keymap beats an editor-wide one", (c.winner == &a ? ka : kb).name)
			case ka.priority != kb.priority:
				if ka.priority > kb.priority { c.winner = &a } else { c.winner = &b }
				c.why = fmt.tprintf("%s wins by priority", (c.winner == &a ? ka : kb).name)
			case:
				// _keymaps is sorted: ka comes first.
				c.winner = &a
				c.why = fmt.tprintf("%s wins by name", ka.name)
			}
			append(&out, c)
		}
	}
	return out[:]
}

// --- Display and capture ---------------------------------------------------------

// The chord as the Shortcuts page and the menu show it: "Ctrl+Shift+T", with
// Cmd for Ctrl on macOS, where imgui maps the physical Cmd key to Ctrl.
// Temp.
format_chord :: proc(chord: im.KeyChord, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	mods := chord & im.KeyChord(im.Key.ImGuiMod_Mask_)
	if mods & im.KeyChord(im.Key.ImGuiMod_Ctrl) != 0 do strings.write_string(&b, "Cmd+" when ODIN_OS == .Darwin else "Ctrl+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Super) != 0 do strings.write_string(&b, "Ctrl+" when ODIN_OS == .Darwin else "Super+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Alt) != 0 do strings.write_string(&b, "Alt+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Shift) != 0 do strings.write_string(&b, "Shift+")
	strings.write_string(&b, key_name(im.Key(chord & ~im.KeyChord(im.Key.ImGuiMod_Mask_))))
	return strings.to_string(b)
}

// The chord as the declaration spells it, which parse_chord reads back:
// "Ctrl+Shift+T". Temp.
chord_text :: proc(chord: im.KeyChord, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	mods := chord & im.KeyChord(im.Key.ImGuiMod_Mask_)
	if mods & im.KeyChord(im.Key.ImGuiMod_Ctrl) != 0 do strings.write_string(&b, "Ctrl+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Super) != 0 do strings.write_string(&b, "Super+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Alt) != 0 do strings.write_string(&b, "Alt+")
	if mods & im.KeyChord(im.Key.ImGuiMod_Shift) != 0 do strings.write_string(&b, "Shift+")
	strings.write_string(&b, key_name(im.Key(chord & ~im.KeyChord(im.Key.ImGuiMod_Mask_))))
	return strings.to_string(b)
}

// The name parse_key reads for `key`: "A", "F2", "Space", "Left".
key_name :: proc(key: im.Key) -> string {
	k := int(key)
	switch {
	case key >= .A && key <= .Z: return _LETTERS[k - int(im.Key.A):][:1]
	case key >= ._0 && key <= ._9: return _DIGITS[k - int(im.Key._0):][:1]
	case key >= .F1 && key <= .F12: return _F_KEYS[k - int(im.Key.F1)]
	}
	#partial switch key {
	case .Comma:        return ","
	case .Period:       return "."
	case .Minus:        return "-"
	case .Equal:        return "="
	case .Slash:        return "/"
	case .LeftBracket:  return "["
	case .RightBracket: return "]"
	case .Semicolon:    return ";"
	case .Apostrophe:   return "'"
	case .Backslash:    return "\\"
	case .GraveAccent:  return "`"
	case .Space:        return "Space"
	case .Escape:       return "Escape"
	case .Enter:        return "Enter"
	case .Tab:          return "Tab"
	case .Backspace:    return "Backspace"
	case .Delete:       return "Delete"
	case .Insert:       return "Insert"
	case .Home:         return "Home"
	case .End:          return "End"
	case .PageUp:       return "PageUp"
	case .PageDown:     return "PageDown"
	case .LeftArrow:    return "Left"
	case .RightArrow:   return "Right"
	case .UpArrow:      return "Up"
	case .DownArrow:    return "Down"
	case .LeftShift:    return "LeftShift"
	case .RightShift:   return "RightShift"
	case .LeftCtrl:     return "LeftCtrl"
	case .RightCtrl:    return "RightCtrl"
	case .LeftAlt:      return "LeftAlt"
	case .RightAlt:     return "RightAlt"
	}
	return "?"
}

@(private = "file")
_LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
@(private = "file")
_DIGITS := "0123456789"
@(private = "file")
_F_KEYS := [12]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}

// While the Shortcuts page listens for a chord, the resolver runs nothing:
// the key being captured must not also run a command.
capturing: bool

// The chord pressed this frame, for the Shortcuts page while it listens: the
// first named key down with the modifiers held. A modifier key alone is a
// chord of its own (LeftShift), taken on its release so a chord that starts
// with it can still come. `escape` is true when the capture was cancelled.
capture_chord :: proc() -> (chord: im.KeyChord, got: bool, escape: bool) {
	io := im.GetIO()
	if im.IsKeyPressed(.Escape, false) do return 0, false, true
	for k in int(im.Key.NamedKey_BEGIN) ..< int(im.Key.NamedKey_END) {
		key := im.Key(k)
		if key >= .MouseLeft && key <= .MouseWheelY do continue
		if key >= .GamepadStart && key <= .GamepadRStickDown do continue
		// imgui's stand-ins for the modifier flags read as pressed with the
		// flag: they are no keys.
		if key >= .ReservedForModCtrl && key <= .ReservedForModSuper do continue
		if _is_modifier_key(key) {
			if im.IsKeyReleased(key) && io.KeyMods == 0 do return im.KeyChord(key), true, false
			continue
		}
		if key_name(key) == "?" do continue
		if im.IsKeyPressed(key, false) do return io.KeyMods | im.KeyChord(key), true, false
	}
	return 0, false, false
}

@(private = "file")
_is_modifier_key :: proc(key: im.Key) -> bool {
	#partial switch key {
	case .LeftShift, .RightShift, .LeftCtrl, .RightCtrl, .LeftAlt, .RightAlt, .LeftSuper, .RightSuper: return true
	}
	return false
}
