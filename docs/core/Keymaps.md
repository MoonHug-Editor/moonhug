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
```

- `name` is `Group/Title`, the group being the window or feature it belongs to, in spaced words.
- `id` is the command's stable identity, which bindings and the override file refer to. It defaults to the declaring proc's qualified name, `editor.scene_tool_translate`, so a renamed title or a moved menu item keeps the user's bindings. Give one when the proc itself is renamed. A menu item's id is its proc's qualified name the same way, or its `@(menu_item)` `id`.
- `enabled` names a proc in the same package that says whether the command can run now. A disabled command leaves its key to the next binding.
- A command never reads a modifier key to decide what it does: the chord carries the modifier, and a different action is a different command. Collapse and Collapse Subtree are two commands, bound to Left and Alt+Left, so each can be rebound on its own.
- Every item and toggle of the main menu is a command named by its path (`Edit/Undo`), registered by the menu with the item. Its `shortcut=` is a binding in the `Menu` keymap.

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
}
```

- `window` is the id of the `@(editor_window)` the keymap serves. It resolves only while an instance of that window is focused. Without it the keymap serves the whole editor.
- `active` names a proc that says whether the keymap resolves this frame, on top of its window being focused.
- `modal` makes it a tool's keymap: off until the tool pushes it with `keymap.push`, then the only one that resolves, bound chords and unbound alike, until the tool pops it. The flythrough pushes its keymap when the camera starts flying and pops it when it stops, so `W` moves the camera instead of picking the editor-wide translate tool. A modal keymap has no window and no rule, and conflicts with nothing. The page lists it under Tools.
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
- Every conflict is logged once at startup, after the overrides loaded, with the resolver's verdict, and a keymap registered later logs its own. The Shortcuts page shows the same.
- The focused view's keymaps come first, by priority, then the keymaps of the view hosting it (a Workspace view), then the editor-wide ones. A view's binding beats its host's, which beats a global binding of the same chord. A number never beats the level: priority orders keymaps inside one level only.
- One press runs one command. A chord a command took is done for the frame. A disabled command does not take its chord.
- A press goes through imgui's shortcut routing with global scope, so a text field being typed in, an open dialog or any other key owner wins, as it does for a menu shortcut.
- Keys go to the clicked view. The focused window is the open instance whose imgui window, or a child window of it, has focus (`window.focused()`), which a view in a Workspace frame has as a frame of its own. Any mouse button's click on a view's content focuses it, so the right-button flythrough starts in a focused Scene view. There is no hover focus. Maximize keeps acting on the view under the mouse.

## Preferences

The Shortcuts tab of the settings window lists every registered command, one row each, grouped by the command's group, with its bindings in every context. A context is a keymap: the window it serves and its rule, named by the keymap, with the scope in the chip's tooltip. A binding is a line: a remove button, the context, the chord as a button. Click the chord and press the new one, Escape cancels, Backspace removes the binding as the remove button does. The plus on a row adds a binding: pick the context it applies in, then press the chord. That is how one command is reached from several views, and a command may be bound in a context its plugin never declared. The search box filters by command name, by chord, or by context.

- A command whose bindings differ from the defaults in any context shows Reset to default beside its plus, which puts every context back. Reset All does it for every command.
- Two bindings one chord can reach in the same frame are a conflict: same window, or one editor-wide. The binding shows a warning with the resolver's verdict, which one runs and why. Nothing is blocked.
- A binding whose command is not loaded is listed under Not loaded and kept.
- Overrides live in `UserSettings/shortcuts.json`, per developer, never committed, as keymap name, command id and the chord list. Defaults stay in code. An override for a keymap that is not registered stays in the file and applies when that keymap registers, so a plugin turned off and on, or a view that registers its keymap at runtime, keeps the user's bindings.
- The bridge lists commands with their bindings (`commands`) and runs one by id or name (`run_command`), see [McpBridge](McpBridge.md).
- The main menu shows the live bindings of its items, overrides included: the first two chords, and every chord in the item's tooltip when there are more.
- A command is one thing wherever it is reached: a view binds the Edit menu's Copy, Delete or Frame Selected in its own keymap instead of declaring a command of its own, so the page lists it once with every context. A view's own commands are the ones only it has, such as a list's Select Down.

## Keys every view shares

The `Views` keymap is editor-wide: Ctrl+W closes the focused view, as its tab's Close Tab does, Ctrl+Shift+T brings back the view closed last, and Shift+Space maximizes the view under the mouse or puts the maximized one back. A view holding unapplied edits still asks before it closes. A reopened view returns to the dock node and tab place it left, or to the Workspace frame it was closed from while that frame is still there. Otherwise it gets a window of its own.

## Ctrl and Cmd

A chord is written with `Ctrl` meaning the platform's primary modifier, which imgui maps to Cmd on macOS, and `Super` the other one. The page and the menu show the platform's name, so `Ctrl+S` reads Cmd+S on a Mac. A platform that wants a different key altogether declares it with `mac` on the binding.

## What is still read directly

Every view's keys are commands in its keymap. A few reads stay direct, because they are not view shortcuts: the add component popup's keys (it is a popup with its own search field), the maximize shortcut (it acts on the view under the mouse, not the focused one), the dialog's and the text input's hooks (they belong to the widget that owns the keyboard), and modifier reads at a click, such as Shift or Ctrl held while a row is clicked. User overrides and a Shortcuts window come next.
