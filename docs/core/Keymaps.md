---
title: "Keymaps"
description: "Editor commands and keymaps: how a key reaches a view, the attributes a plugin declares its shortcuts with, and the resolver's rules"
weight: 115
tags: ["keymaps", "shortcuts", "commands", "attributes", "editor"]
path: editor
---

The editor's keys are commands bound in keymaps, resolved once per frame by `moonhug/editor/keymap`. A view reads no keys itself. The editor and every plugin ship as many keymaps as they have features, each one a small set of bindings with a rule for when it is active. The game's input lives in the input actions plugin and shares nothing with this.

## Commands

A command is a named proc the editor can run from a key, a menu, a palette or the bridge. It is declared with `@(command)` on a proc that takes nothing.

```odin
@(command={name="Scene/Frame Selected"})
scene_frame_selected_command :: proc() { ... }

@(command={name="Scene/Clear Selection", enabled=scene_can_clear_selection})
scene_clear_selection :: proc() { ... }

@(command={name="View/Close", enabled=view_close_can, help="Closes the focused view"})
view_close_focused :: proc() { ... }

view_close_can :: proc() -> bool {
	if wnd.focused() == nil do return keymap.disabled("No view has focus")
	return true
}
```

- `name` is `Group/Title`, the group being the window or feature it belongs to, in spaced words.
- `id` is the command's stable identity, which bindings and the override files refer to. The Commands reference page, written by `mh docs`, lists every id. It defaults to the declaring proc's qualified name, `editor.scene_tool_translate`, so a renamed title or a moved menu item keeps the user's bindings. Give one when the proc itself is renamed. A menu item's id is its proc's qualified name the same way, or its `@(menu_item)` `id`.
- `enabled` names a proc in the same package that says whether the command can run now. A disabled command leaves its key to the next binding.
- An `enabled` proc that knows why the command cannot run returns `keymap.disabled("why")` where it would return false. The command palette shows the reason under the dimmed row's name, the menu in the item's tooltip. `keymap.command_state` returns a command's enabled state with that reason. The reason is a literal or temp.
- `help` is one sentence on what the command does, in the present tense, starting with a verb: "Closes the focused view". The generated Assets/Create and Component items get one from their title. Prebuild warns about a `@(command)`, `@(menu_item)` or `@(command_palette_mode)` declared without one, with its file and line. The command palette shows it dimmed on a second line under the name, the Shortcuts page and the menu in the tooltip, and the Commands reference page in its own column. `@(menu_item)` and `@(command_palette_mode)` take `help` too.
- `palette=false` keeps it out of the command palette, for a step of a focused list's navigation that only makes sense as a key.
- A command never reads a modifier key to decide what it does: the chord carries the modifier, and a different action is a different command. Collapse and Collapse Subtree are two commands, bound to Left and Alt+Left, so each can be rebound on its own.
- Every item and toggle of the main menu is a command named by its path (`Edit/Undo`), registered by the menu with the item. Its `shortcut=` is a binding in the `Menu` keymap, or several: chords separated by a comma and a space, `shortcut="Ctrl+Shift+Z, Ctrl+Y"`. A chord has no space in it, so `"Ctrl+,, F5"` is Ctrl+, and F5. `@(command_palette_mode)` reads `shortcut` the same way.

## Commands with arguments

A command whose proc takes a pointer to a struct runs with arguments: the values in the struct. `defaults=` names a constant of the struct for the values it starts with, the zero value without one.

```odin
Duplicate_Array_Args :: struct {
	count:  int,
	offset: [3]f32,
}

DUPLICATE_ARRAY_DEFAULT :: Duplicate_Array_Args{count = 3, offset = {1, 0, 0}}

@(command={name="Edit/Duplicate Array", enabled=duplicate_array_can, defaults=DUPLICATE_ARRAY_DEFAULT, update=duplicate_array_update, help="Duplicates the selection several times, each copy a step further along an offset"})
edit_duplicate_array :: proc(args: ^Duplicate_Array_Args) { ... }

// A new offset moves the copies the last run made. A new count returns false.
duplicate_array_update :: proc(args: ^Duplicate_Array_Args) -> bool { ... }
```

- A key, the menu, the palette or the bridge runs it at once with the values it last used, as one undo step: the run is wrapped in an undo group.
- The command's settings panel then shows those values at the bottom left of the editor, drawn by the inspector. It takes no keyboard focus and blocks no view, and it collapses to its title bar. Changing a value undoes the last run and runs the command again with the new values, unless the command's update proc applies it in place, so the history keeps one step and a dragged value updates the result live.
- `update=` names a proc that applies changed values to what the last run made, in place, instead of undoing it and running again: Duplicate Array moves its copies for a new offset. The panel tries it first on every change, and runs the command again when it returns false.
- An update proc takes the command's arguments pointer and returns a bool. The prebuild fails with the declaration's place when the proc is missing or its signature differs.
- An update proc decides first and changes after: it returns false before it changes anything. A change made before returning false would stay outside the undo step.
- An update proc records its edits the usual way, with `undo.edit_begin` and `undo.edit_end`. The panel folds them into the run's undo step with `undo.amend_begin`, so undo takes back the run and its adjustments together, and redo makes the result again and applies them.
- A folded edit of a field the step already edits replaces that edit's new value, so a value dragged on every frame keeps one edit per field.
- Anything else that records an undo step, an undo or a redo closes the panel: the run is no longer the last step. A run that recorded nothing closes it too, since there is nothing to adjust.
- The reset icon at the right of the panel's title bar puts the command's declared defaults back. It is disabled while the values are the defaults. A reset is a change like any other: the result is redone with the defaults, still as one step.
- `ask=true` opens the panel before the first run, with a Run button, for a command whose values should be chosen first.
- The last values used are kept per command in the editor settings, so they survive a restart.
- The arguments are plain values: numbers, bools, enums, and arrays and structs of them. A string, a pointer, a slice, a map or a dynamic array in them panics at registration with the command's origin.
- The struct carries no `decor:` tags when its package imports the inspector: the inspector's generated decorators would import that package back.
- The bridge's `commands` lists each command's current arguments, and `run_command` takes `args`, the fields to set before it runs. The values set stay as the last used.
- `keymap.command_args_json` and `keymap.command_args_set_json` read and write the values as JSON, `keymap.command_args_reset` puts the defaults back.
- Values per binding, one command bound twice with different arguments, are not supported yet.

## Keymaps

A keymap is declared with `@(keymap)` on a proc that takes `^keymap.Keymap` and binds its chords.

```odin
@(keymap={name="Scene Tools"})
scene_tools_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "W", "Scene/Translate Tool")
}

@(keymap={name="Scene View", window="Scene"})
scene_view_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "F", "Scene/Frame Selected")
	keymap.bind(km, "Escape", "Scene/Clear Selection")
}

@(keymap={name="Scene Flythrough", modal=true})
scene_flythrough_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "W", "Scene/Fly Forward", held = true)
	keymap.bind(km, "LeftShift", "Scene/Fly Fast", held = true)
	keymap.quick_help_add(km, "Right Mouse", "Release to stop flying")
}
```

- `window` is the id of the `@(editor_window)` the keymap serves. It resolves only while an instance of that window is focused. Without it the keymap serves the whole editor.
- `active` names a proc that says whether the keymap resolves this frame, on top of its window being focused.
- `modal` makes it a tool's keymap: off until the tool pushes it with `keymap.push`, then the only one that resolves, bound chords and unbound alike, until the tool pops it. The flythrough pushes its keymap when the camera starts flying and pops it when it stops, so `W` moves the camera instead of picking the editor-wide translate tool. A modal keymap has no window and no rule, and conflicts with nothing. The page lists it under Tools.
- While a tool's keymap is on top, the status bar shows its quick help in place of the last log line: the keymap's name, then each bound command once, its chords on a key cap and its title after them, so an override shows there too. `keymap.quick_help_add(km, keys, text)` in the fill proc adds the keys and mouse actions the tool reads itself, listed after the bindings and never on the Shortcuts page. A tool's keymap with no bindings and no added lines, the command palette's, leaves the log line.
- The Quick Help section of the settings window turns it off, for every tool or for one tool keymap such as the flythrough's: its tool list has a checkbox per tool keymap that has something to show. It is `keymap.quick_help_settings`, a `@(system_settings)` tab saved to `quick_help.json`, the same for every project on the machine, drawn, saved and undone like every other settings tab.
- `consume` ends resolution after this keymap while it is active, for every key, bound or not. For a keymap that is not a tool's but still owns the keys while a condition holds.
- `priority` orders keymaps of one scope, highest first. Without it keymaps of equal priority resolve by name.
- A binding names its command. The command may live in another package, or in a plugin that is off: the binding is then inert, and `keymap.dangling()` lists it for the Shortcuts window and the tests.
- `held` runs the command every frame while the chord is down instead of once on the press. A held chord's modifiers may be a subset of the ones held, so `W` keeps moving while Shift makes it fast.
- `repeat` makes a press repeat while the key stays down, for arrow keys in a list.
- `mac` is the chord on macOS when it differs, data beside the other platforms' chord, the way a keybinding rule carries a `mac` field: `keymap.bind(km, "F2", "Project/Rename", mac = "Enter")`. No `when ODIN_OS` in a keymap proc.

A chord is written as `Ctrl+S`, `Shift+Space`, `F2`, `Escape`, `LeftShift`. `Ctrl` is Cmd on macOS. Keys are letters, digits, `F1` to `F12`, `Space`, `Escape`, `Enter`, `Tab`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `PageUp`, `PageDown`, the arrows as `Left` `Right` `Up` `Down`, the modifier keys as `LeftShift` and the like, and `, . - = / [ ] ; ' \ `` ` `` as the character. Case does not matter. A chord that does not parse panics at registration with the keymap's origin.

## Resolution

`keymap.frame()` runs once per frame from the main loop, after the imgui frame starts and before the views draw, so a command's effect shows the same frame.

- Nothing resolves while a modal popup is open.
- A tool's keymap on top of the modal stack resolves alone.
- A button that runs a command shows the command's live chord in its tooltip, `keymap.labelled("Move", "Scene/Translate Tool")`, so an override shows there too. The scene tool strip and the Play and Pause buttons do.
- Every conflict is logged once at startup, after the overrides loaded, with the resolver's verdict, and a keymap registered later logs its own. The Shortcuts page shows the same.
- The focused view's keymaps come first, by priority, then the keymaps of the view hosting it (a Workspace view), then the editor-wide ones. A view's binding beats its host's, which beats a global binding of the same chord. A number never beats the level: priority orders keymaps inside one level only.
- One press runs one command. A chord a command took is done for the frame. A disabled command does not take its chord.
- A press goes through imgui's shortcut routing with global scope, so a text field being typed in, an open dialog or any other key owner wins, as it does for a menu shortcut.
- Keys go to the clicked view. The focused window is the open instance whose imgui window, or a child window of it, has focus (`window.focused()`), which a view in a Workspace frame has as a frame of its own. Any mouse button's click on a view's content focuses it, so the right-button flythrough starts in a focused Scene view. There is no hover focus. Maximize keeps acting on the view under the mouse.

## Preferences

The Shortcuts tab of the settings window lists every registered command, one row each, grouped by the command's group, with its bindings in every context. A context is a keymap: the window it serves and its rule, named by the keymap, with the scope in the chip's tooltip. A binding is a line: a remove button, the context, the chord as a button. Click the chord and press the new one, Escape cancels, Backspace removes the binding as the remove button does. The plus on a row adds a binding: pick the context it applies in, then press the chord. That is how one command is reached from several views, and a command may be bound in a context its plugin never declared. The search box filters by command name, by chord, or by context.

- A command whose bindings differ from the defaults in any context shows Reset to default beside its plus, which puts every context back. Reset All does it for every command, after a dialog that says undo does not restore the bindings.
- A command's tooltip shows its help, its id and where it is declared.
- Two bindings one chord can reach in the same frame are a conflict: same window, or one editor-wide. The binding shows a warning with the resolver's verdict, which one runs and why. Nothing is blocked.
- A binding whose command is not loaded is listed under Not loaded and kept.
- Overrides live in one file, `shortcuts.json` under the OS user's config folder, Application Support on macOS, as keymap name, command id and the chord list, defaults stay in code. It is the developer's, machine-wide, the same for every project, and never in the project's folder. An override for a keymap that is not registered stays in the file and applies when that keymap registers, so a plugin turned off and on, or a view that registers its keymap at runtime, keeps the user's bindings.
- The bridge lists commands with their bindings (`commands`) and runs one by id or name (`run_command`), see [McpBridge](McpBridge.md).
- The main menu shows the live bindings of its items, overrides included: the first two chords, and every chord in the item's tooltip when there are more. The tooltip also shows the item's help, and the reason it cannot run while it is disabled.
- A command is one thing wherever it is reached: a view binds the Edit menu's Copy, Delete or Frame Selected in its own keymap instead of declaring a command of its own, so the page lists it once with every context. A view's own commands are the ones only it has, such as a list's Select Down.

## Command palette

Window/Command Palette, Ctrl+T or the key left of 1, opens a popup over the editor that searches one mode's rows: commands by default, or the mode whose prefix the text starts with. The mode's name shows beside the search field.

| Mode | Prefix | Opens with | Lists | Enter |
|---|---|---|---|---|
| Commands | none | Ctrl+T, `` ` `` | the commands with their first two chords | runs the command |
| Assets | `#` | Ctrl+Shift+A | every asset file by name with its Project view icon, its folder beside it | selects it and opens it, as a double-click in the Project view does |
| Scene Objects | `@` | Ctrl+Shift+O | every object of the open scenes in hierarchy order with its Hierarchy glyph, its scene and parents beside it | selects it, reveals it in the Hierarchy and frames it |
| Views | `:` | no default | every view with its icon, the open ones marked | brings an open view forward, in its Workspace frame when it is in one, or opens a closed one |

- The key left of 1 is the menu item's second chord. It is one key on every layout, shown as `` ` ``: imgui's SDL backend maps it by position, so it opens the palette where a German layout types `^`, a French one `²` and a Nordic one `§`. It is a plain key, so a text field being edited gets it as a character, and the game gets it while it runs in a focused Game view.
- Each mode has a command, Command Palette/<name>, that opens the palette with its prefix typed, so its chord is rebound on the Shortcuts page like any other.
- Typing filters by name: every space-separated term must match, case ignored. A term matches as a substring, or as prefixes of the name's words in order, so `fs` and `frsel` find Frame Selected. A word starts after a character that is not a letter or a digit, at a capital after a lowercase letter, and at a digit after a letter. A term with a dot matches a command's id too, `editor.edit_undo_menu`, and a term with a slash matches an asset's path, `#ui/`.
- Rows are ranked by how their labels match, best first: a term at the start of the title, the text after the last slash, then at the start of a title word, then at the start of a word before the title, then prefixes of the title's words, then prefixes that reach before the title, then a substring inside a word. A whole word ranks a little higher. Among equal matches a row that can run comes before one that cannot. The letters that matched show in the theme's accent colour.
- Rows run recently come next among equal matches, and first when nothing is typed. Each mode keeps its last 20 by the row's key, in the editor settings, so they survive a restart.
- Commands leave out a held modifier, a command every binding of which is held such as Fly Forward or Snap, and a command declared with `palette=false`, which a step of a focused list's navigation is (Select Down, Expand, Clear Filter). A command shows its help dimmed on a second line under its name, so every note starts at the same place. A command that cannot run now is listed dimmed, with the reason its `enabled` proc gave in place of the help. A note cut short shows whole in the row's tooltip. A row without a note is one line, every other row has the theme's alternate row background, and only the rows in view are drawn.
- `?` typed alone shows the help: every mode with its prefix and its live chord, how terms match, then the palette's keys. The field's hint says so. Enter or a click on a mode switches to it. Typing leaves the help.
- Up and Down move the highlight, Enter or a click runs the highlighted row and closes the palette, Escape closes it.
- The view focused when the palette opened stays the focused one while it is open, so a command's enabled state and its run are for that view: View/Close closes it.
- While the palette is open its empty modal keymap sits on the stack, so no other binding fires. The palette's own keys belong to the widget, like the dialog's.

A mode is declared with `@(command_palette_mode)` on a proc that lists its rows:

```odin
@(command_palette_mode={name="Assets", prefix="#", run=command_palette_assets_run, shortcut="Ctrl+Shift+A", help="Finds an asset by name or folder and opens it"})
command_palette_assets :: proc(query: string, rows: ^[dynamic]command_palette.Row) { ... }

command_palette_assets_run :: proc(row: command_palette.Row) { ... }
```

- The list proc runs every frame the mode is shown. It gets the text after the prefix with spaces trimmed and appends the matching rows. `command_palette.terms` splits the query and `command_palette.matches` tests a name against it without allocating. The palette ranks the rows, so the order the proc appends them in only breaks ties.
- A row has an icon, a label, a dimmed detail on the right, a help line, a disabled flag with its reason, and a key or a pointer that identifies it for `run`. When any row of a list has an icon, every row gets the icon column, so the labels line up. A row with a key can rank as recently run. Its strings live until the frame ends.
- `command_palette.rows_for(text)` returns the rows the palette shows for a text, ranked, for tests and tools.
- `run` acts on the picked row in the frame it was listed.
- `shortcut` binds the mode's command in the editor-wide Command Palette Modes keymap. `id` is that command's stable id, the list proc's qualified name by default. `help` is that command's help, shown in the palette and as the mode's tooltip in the `?` help.
- An empty prefix, one starting with `?`, or another mode's prefix panics at registration with both origins.

## Keys every view shares

The `Views` keymap is editor-wide: Ctrl+W closes the focused view, as its tab's Close Tab does, Ctrl+Shift+T brings back the view closed last, and Shift+Space maximizes the view under the mouse or puts the maximized one back. A view holding unapplied edits still asks before it closes. A reopened view returns to the dock node and tab place it left, or to the Workspace frame it was closed from while that frame is still there. Otherwise it gets a window of its own.

## Snap

The snap modifier is one command, `Handles/Snap`, held on Ctrl (Cmd on macOS) in the editor-wide `Snap` keymap. Every handle reads it: the transform gizmo, a component's handles and the rect tool's pivot. While it is held, snapping flips from the Snap popup's toggle, so it snaps when the toggle is off and drags freely when it is on. It is the only binding of the command, so one rebinding moves snap everywhere.

## Ctrl and Cmd

A chord is written with `Ctrl` meaning the platform's primary modifier, which imgui maps to Cmd on macOS, and `Super` the other one. The page and the menu show the platform's name, so `Ctrl+S` reads Cmd+S on a Mac. A platform that wants a different key altogether declares it with `mac` on the binding.

## What is still read directly

Every view's keys and the main menu's shortcuts are commands in keymaps.

A few reads stay direct:
- the dialog's Enter and Escape and the text input's Escape hook
- The add component popup's keys (a popup with its own search field)
- a modifier held during a mouse action, such as Shift+click extending a selection or Alt on the toolbar's Play. The mouse is the input there and the modifier a flag on it, so no chord resolves and the Shortcuts page cannot rebind them, as in every editor.
