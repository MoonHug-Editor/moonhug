package editor

// The Shortcuts tab of the settings window (docs/core/Keymaps.md): one row
// per registered command, grouped by the command's group, with its bindings
// across every context. A context is a keymap: the window it serves and its
// rule. A binding is a chord button that listens for a new chord when
// clicked, with the context beside it, a conflict mark with the resolver's
// verdict, and a reset where the command's bindings in that context differ
// from the defaults. Edits are overrides in UserSettings/shortcuts.json, per
// developer (editor/keymap).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/keymap"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"

@(private = "file")
_sc: struct {
	filter:     [64]byte,
	// The binding listening for a chord: its keymap, command and the index
	// of the chord among the command's chords in that keymap, the count for
	// a new one.
	listen_km:  ^keymap.Keymap,
	listen_cmd: string, // owned
	listen_idx: int,
	// The command whose context picker is open.
	pick_cmd:   string, // owned
}

@(phase={key=core.Phase.EditorInit, order=1, mode=Editor})
shortcuts_tab_install :: proc() {
	settings_add_custom_tab("Shortcuts", shortcuts_draw)
}

shortcuts_shutdown :: proc() {
	_listen_stop()
	_pick_stop()
}

@(private = "file")
_listen_start :: proc(km: ^keymap.Keymap, command: string, idx: int) {
	_listen_stop()
	_sc.listen_km = km
	_sc.listen_cmd = strings.clone(command, runtime.default_allocator())
	_sc.listen_idx = idx
	keymap.capturing = true
}

@(private = "file")
_listen_stop :: proc() {
	if _sc.listen_cmd != "" do delete(_sc.listen_cmd, runtime.default_allocator())
	_sc.listen_cmd = ""
	_sc.listen_km = nil
	keymap.capturing = false
}

@(private = "file")
_pick_stop :: proc() {
	if _sc.pick_cmd != "" do delete(_sc.pick_cmd, runtime.default_allocator())
	_sc.pick_cmd = ""
}

// The chords of `command` in `km`, as declared. Temp.
@(private = "file")
_chords_of :: proc(km: ^keymap.Keymap, command: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for b in km.bindings do if b.command == command do append(&out, b.text)
	return out[:]
}

// A window's title as its tab shows it, the id when it is not registered.
@(private = "file")
_window_title :: proc(id: string) -> string {
	for w in wnd.registered() do if w.id == id do return w.title
	return id
}

// A keymap's scope in words, for its context chip's tooltip.
@(private = "file")
_keymap_scope :: proc(km: ^keymap.Keymap) -> string {
	b := strings.builder_make(context.temp_allocator)
	if km.window == "" {
		strings.write_string(&b, "editor-wide")
	} else {
		fmt.sbprintf(&b, "%s window", _window_title(km.window))
	}
	if km.active != nil do strings.write_string(&b, ", when its rule allows")
	if km.consume do strings.write_string(&b, ", takes every key")
	if km.priority != 0 do fmt.sbprintf(&b, ", priority %d", km.priority)
	return strings.to_string(b)
}

// Whether a command's row shows under the filter: its name, one of its
// chords, or the name of a context it is bound in matches.
@(private = "file")
_matches_filter :: proc(command: string, filter: string) -> bool {
	if filter == "" do return true
	if strings.contains(strings.to_lower(command, context.temp_allocator), filter) do return true
	for km in keymap.keymaps() {
		for b in km.bindings {
			if b.command != command do continue
			if strings.contains(strings.to_lower(km.name, context.temp_allocator), filter) do return true
			if strings.contains(strings.to_lower(b.text, context.temp_allocator), filter) do return true
			if strings.contains(strings.to_lower(keymap.format_chord(b.chord), context.temp_allocator), filter) do return true
		}
	}
	return false
}

// The command's group and title: "Scene/Translate Tool" is Scene, Translate Tool.
@(private = "file")
_split_name :: proc(name: string) -> (group, title: string) {
	if i := strings.index_byte(name, '/'); i >= 0 do return name[:i], name[i + 1:]
	return "Other", name
}

// Drops the binding at `idx` among `command`'s chords in `km`.
@(private = "file")
_remove_binding :: proc(km: ^keymap.Keymap, command: string, idx: int) {
	chords := make([dynamic]string, context.temp_allocator)
	for text in _chords_of(km, command) do append(&chords, text)
	if idx < len(chords) do ordered_remove(&chords, idx)
	keymap.override_set(km, command, chords[:])
}

// One command's bindings, one line each: remove, its context, the chord.
// `loaded` is false for a binding whose command is not registered.
@(private = "file")
_draw_bindings :: proc(command: string, conflicts: []keymap.Conflict, by_binding: map[^keymap.Binding]int, loaded: bool) {
	for km in keymap.keymaps() {
		idx := 0
		im.PushIDPtr(km)
		for &b in km.bindings {
			if b.command != command do continue
			im.PushIDInt(i32(idx))
			if im.SmallButton(icons.ICON_MD_CLOSE) {
				_listen_stop()
				_remove_binding(km, command, idx)
				im.PopID()
				break
			}
			widgets.tooltip("Remove this binding")
			im.SameLine(0, 6)
			im.TextDisabled("%s", strings.clone_to_cstring(km.name, context.temp_allocator))
			widgets.tooltip(fmt.ctprintf("%s\n%s", _keymap_scope(km), km.origin))
			im.SameLine(0, 6)
			listening := _sc.listen_km == km && _sc.listen_cmd == command && _sc.listen_idx == idx
			label := "Press keys..." if listening else strings.clone_to_cstring(keymap.format_chord(b.chord), context.temp_allocator)
			if listening do im.PushStyleColor(.Button, im.GetColorU32(.ButtonActive))
			if im.Button(label) do _listen_start(km, command, idx)
			if listening do im.PopStyleColor()
			widgets.tooltip("Click, then press the new chord")
			if b.held || b.repeat {
				im.SameLine(0, 4)
				im.TextDisabled("%s", cstring("held" if b.held else "repeat"))
			}
			if ci, has := by_binding[&b]; has {
				cf := conflicts[ci]
				other := cf.km_b if cf.a == &b else cf.km_a
				im.SameLine(0, 4)
				im.TextColored({1, 0.7, 0.2, 1}, icons.ICON_MD_WARNING)
				widgets.tooltip(fmt.ctprintf("Also bound in %s. %s.", other.name, cf.why))
			}
			idx += 1
			im.PopID()
		}
		if idx == 0 && !keymap.is_default(km, command) {
			// Unbound by an override: the default had chords here.
			im.TextDisabled("%s", fmt.ctprintf("none in %s", km.name))
		}
		im.PopID()
	}
	// A new chord being listened for: its line, under the others.
	if _sc.listen_km != nil && _sc.listen_cmd == command && _sc.listen_idx == len(_chords_of(_sc.listen_km, command)) {
		im.TextDisabled("%s", strings.clone_to_cstring(_sc.listen_km.name, context.temp_allocator))
		im.SameLine(0, 6)
		im.PushStyleColor(.Button, im.GetColorU32(.ButtonActive))
		im.SmallButton("Press keys...")
		im.PopStyleColor()
	}
}

// Whether the command's bindings differ from the defaults in any context.
@(private = "file")
_command_overridden :: proc(command: string) -> bool {
	for km in keymap.keymaps() do if !keymap.is_default(km, command) do return true
	return false
}

// At the right of the command's name: the reset to default when any context
// differs, then the plus, which picks the context and listens for the chord.
@(private = "file")
_draw_plus :: proc(command: string) {
	pad := im.GetStyle().FramePadding.x * 2
	w := im.CalcTextSize(icons.ICON_MD_ADD).x + pad
	overridden := _command_overridden(command)
	if overridden do w += im.CalcTextSize(icons.ICON_MD_REFRESH).x + pad + im.GetStyle().ItemSpacing.x
	im.SameLine()
	im.SetCursorPosX(im.GetCursorPosX() + max(im.GetContentRegionAvail().x - w, 0))
	if overridden {
		if im.SmallButton(icons.ICON_MD_REFRESH) {
			_listen_stop()
			for km in keymap.keymaps() do if !keymap.is_default(km, command) do keymap.override_reset(km, command)
		}
		widgets.tooltip("Reset to default")
		im.SameLine()
	}
	picking := _sc.pick_cmd == command
	if im.SmallButton(icons.ICON_MD_ADD) {
		_pick_stop()
		_sc.pick_cmd = strings.clone(command, runtime.default_allocator())
		im.OpenPopup("##sc_pick")
	}
	widgets.tooltip("Add new binding: pick where it applies, then press the chord")
	if picking && im.BeginPopup("##sc_pick") {
		// Editor-wide keymaps in one submenu, the views' keymaps under their
		// window in another.
		if im.BeginMenu("Editor-wide") {
			for km in keymap.keymaps() do if km.window == "" do _pick_item(km, command)
			im.EndMenu()
		}
		if im.BeginMenu("Views") {
			windows := make([dynamic]string, context.temp_allocator)
			for km in keymap.keymaps() do if km.window != "" && !slice.contains(windows[:], km.window) do append(&windows, km.window)
			slice.sort(windows[:])
			for window in windows {
				// One keymap: the window's item is the keymap. Several: a
				// submenu of them.
				count := 0
				only: ^keymap.Keymap
				for km in keymap.keymaps() do if km.window == window {
					count += 1
					only = km
				}
				title := strings.clone_to_cstring(_window_title(window), context.temp_allocator)
				if count == 1 {
					_pick_item(only, command, title)
				} else if im.BeginMenu(title) {
					for km in keymap.keymaps() do if km.window == window do _pick_item(km, command)
					im.EndMenu()
				}
			}
			im.EndMenu()
		}
		im.EndPopup()
	} else if picking {
		_pick_stop()
	}
}

// One context in the picker: the keymap, with its rule in the label when it
// has one, and its scope in the tooltip.
@(private = "file")
_pick_item :: proc(km: ^keymap.Keymap, command: string, label: cstring = nil) {
	label := label if label != nil else strings.clone_to_cstring(km.name, context.temp_allocator)
	if im.MenuItem(label) {
		_listen_start(km, command, len(_chords_of(km, command)))
		_pick_stop()
		im.CloseCurrentPopup()
	}
	widgets.tooltip(fmt.ctprintf("%s\n%s", _keymap_scope(km), km.origin))
}

shortcuts_draw :: proc() {
	filter_raw := string(cstring(raw_data(_sc.filter[:])))
	filter := strings.to_lower(strings.trim_space(filter_raw), context.temp_allocator)

	// The top bar: search, the conflict count, reset all.
	im.SetNextItemWidth(260)
	im.InputTextWithHint("##sc_filter", "Search commands, keys and contexts", cstring(raw_data(_sc.filter[:])), c.size_t(len(_sc.filter)), {})
	widgets.tooltip("Filters by command name, by chord, or by the context a binding applies in")
	conflicts := keymap.conflicts()
	by_binding := make(map[^keymap.Binding]int, context.temp_allocator)
	for &cf, i in conflicts {
		by_binding[cf.a] = i
		by_binding[cf.b] = i
	}
	im.SameLine()
	if len(conflicts) > 0 {
		im.TextDisabled("%d conflicts", i32(len(conflicts)))
	} else {
		im.TextDisabled("no conflicts")
	}
	im.SameLine()
	im.BeginDisabled(!keymap.has_overrides())
	if im.Button("Reset All") {
		_listen_stop()
		keymap.override_reset_all()
	}
	widgets.tooltip("Every binding back to its default, the override file emptied")
	im.EndDisabled()
	if _sc.listen_km != nil {
		im.SameLine()
		im.TextColored({1, 0.8, 0.3, 1}, "Press keys, Escape cancels, Backspace removes")
	}

	// Every registered command, by group then title. A group is a header,
	// open by default when one of its commands is bound: the menu's groups
	// hold many commands nobody binds. A search opens every group it shows.
	names := make([dynamic]string, context.temp_allocator)
	for cmd in keymap.commands() do if _matches_filter(cmd.name, filter) do append(&names, cmd.name)
	slice.sort(names[:])
	bound := make(map[string]bool, context.temp_allocator)
	for km in keymap.keymaps() do for b in km.bindings do bound[b.command] = true

	i := 0
	for i < len(names) {
		group, _ := _split_name(names[i])
		j := i
		any_bound := false
		for j < len(names) {
			g, _ := _split_name(names[j])
			if g != group do break
			if bound[names[j]] do any_bound = true
			j += 1
		}
		flags: im.TreeNodeFlags
		if any_bound || filter != "" do flags += {.DefaultOpen}
		im.PushID(strings.clone_to_cstring(group, context.temp_allocator))
		if im.CollapsingHeader(fmt.ctprintf("%s###g", group), flags) && im.BeginTable("##commands", 2, im.TableFlags_SizingStretchProp | im.TableFlags_BordersInnerH | im.TableFlags_PadOuterX) {
			im.TableSetupColumn("Command", {.WidthFixed}, 240)
			im.TableSetupColumn("Bindings", {.WidthStretch})
			for name in names[i:j] {
				_, title := _split_name(name)
				im.PushID(strings.clone_to_cstring(name, context.temp_allocator))
				im.TableNextRow()
				im.TableNextColumn()
				im.TextUnformatted(strings.clone_to_cstring(title, context.temp_allocator))
				if c := keymap.command(name); c != nil && c.origin != "" do widgets.tooltip(strings.clone_to_cstring(c.origin, context.temp_allocator))
				_draw_plus(name)
				im.TableNextColumn()
				_draw_bindings(name, conflicts, by_binding, true)
				im.PopID()
			}
			im.EndTable()
		}
		im.PopID()
		i = j
	}

	// Bindings whose command is not registered: its plugin is off. Kept.
	missing := make([dynamic]string, context.temp_allocator)
	for km in keymap.keymaps() do for b in km.bindings {
		if keymap.command(b.command) != nil do continue
		if !slice.contains(missing[:], b.command) && _matches_filter(b.command, filter) do append(&missing, b.command)
	}
	slice.sort(missing[:])
	if len(missing) > 0 && im.CollapsingHeader("Not loaded", {.DefaultOpen}) && im.BeginTable("##missing", 2, im.TableFlags_SizingStretchProp | im.TableFlags_BordersInnerH | im.TableFlags_PadOuterX) {
		im.TableSetupColumn("Command", {.WidthFixed}, 240)
		im.TableSetupColumn("Bindings", {.WidthStretch})
		for name in missing {
			im.PushID(strings.clone_to_cstring(name, context.temp_allocator))
			im.TableNextRow()
			im.TableNextColumn()
			im.TextDisabled("%s", strings.clone_to_cstring(name, context.temp_allocator))
			widgets.tooltip("Command not loaded: its plugin is off. The bindings are kept.")
			im.TableNextColumn()
			_draw_bindings(name, conflicts, by_binding, false)
			im.PopID()
		}
		im.EndTable()
	}

	// Listening: the chord pressed this frame lands in the override.
	if _sc.listen_km != nil {
		km := _sc.listen_km
		command := _sc.listen_cmd
		chord, got, escape := keymap.capture_chord()
		if escape {
			_listen_stop()
		} else if got {
			chords := make([dynamic]string, context.temp_allocator)
			for text in _chords_of(km, command) do append(&chords, text)
			remove := chord == im.KeyChord(im.Key.Backspace)
			switch {
			case remove && _sc.listen_idx < len(chords):
				ordered_remove(&chords, _sc.listen_idx)
			case remove:
			case _sc.listen_idx < len(chords):
				chords[_sc.listen_idx] = keymap.chord_text(chord)
			case:
				append(&chords, keymap.chord_text(chord))
			}
			keymap.override_set(km, command, chords[:])
			_listen_stop()
		}
	}
}
