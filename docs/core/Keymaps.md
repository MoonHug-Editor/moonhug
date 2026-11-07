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
- `enabled` names a proc in the same package that says whether the command can run now. A disabled command leaves its key to the next binding.
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

@(keymap={name="Scene Flythrough", window="Scene", active=scene_is_flying, consume=true, priority=10})
scene_flythrough_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "W", "Scene/Fly Forward", held = true)
	keymap.bind(km, "LeftShift", "Scene/Fly Fast", held = true)
}
```

- `window` is the id of the `@(editor_window)` the keymap serves. It resolves only while an instance of that window is focused. Without it the keymap serves the whole editor.
- `active` names a proc that says whether the keymap resolves this frame, on top of its window being focused. The flythrough keymap is active while the camera flies.
- `consume` ends resolution after this keymap while it is active, for every key, bound or not. The flythrough owns every key while it flies, so `W` moves the camera instead of picking the editor-wide translate tool.
- `priority` orders keymaps of one scope, highest first. Without it keymaps of equal priority resolve by name.
- A binding names its command. The command may live in another package, or in a plugin that is off: the binding is then inert, and `keymap.dangling()` lists it for the Shortcuts window and the tests.
- `held` runs the command every frame while the chord is down instead of once on the press. A held chord's modifiers may be a subset of the ones held, so `W` keeps moving while Shift makes it fast.
- `repeat` makes a press repeat while the key stays down, for arrow keys in a list.

A chord is written as `Ctrl+S`, `Shift+Space`, `F2`, `Escape`, `LeftShift`. `Ctrl` is Cmd on macOS. Keys are letters, digits, `F1` to `F12`, `Space`, `Escape`, `Enter`, `Tab`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `PageUp`, `PageDown`, the arrows as `Left` `Right` `Up` `Down`, the modifier keys as `LeftShift` and the like, and `, . - = / [ ] ; ' \ `` ` `` as the character. Case does not matter. A chord that does not parse panics at registration with the keymap's origin.

## Resolution

`keymap.frame()` runs once per frame from the main loop, after the imgui frame starts and before the views draw, so a command's effect shows the same frame.

- Nothing resolves while a modal popup is open.
- The focused view's keymaps come first, by priority, then the keymaps of the view hosting it (a Workspace view), then the editor-wide ones. A view's binding beats its host's, which beats a global binding of the same chord. A number never beats the level: priority orders keymaps inside one level only.
- One press runs one command. A chord a command took is done for the frame. A disabled command does not take its chord.
- A press goes through imgui's shortcut routing with global scope, so a text field being typed in, an open dialog or any other key owner wins, as it does for a menu shortcut.
- Keys go to the clicked view. The focused window is the open instance whose imgui window, or a child window of it, has focus (`window.focused()`), which a view in a Workspace frame has as a frame of its own. Any mouse button's click on a view's content focuses it, so the right-button flythrough starts in a focused Scene view. There is no hover focus. Maximize keeps acting on the view under the mouse.

## Keys every view shares

The `Views` keymap is editor-wide: Ctrl+W closes the focused view, as its tab's Close Tab does, and Ctrl+Shift+T brings back the view closed last. A view holding unapplied edits still asks before it closes. A reopened view returns to the dock node and tab place it left, or to the Workspace frame it was closed from while that frame is still there. Otherwise it gets a window of its own.

## What is still read directly

Every view's keys are commands in its keymap. A few reads stay direct, because they are not view shortcuts: the add component popup's keys (it is a popup with its own search field), the maximize shortcut (it acts on the view under the mouse, not the focused one), the dialog's and the text input's hooks (they belong to the widget that owns the keyboard), and modifier reads at a click, such as Shift or Ctrl held while a row is clicked. User overrides and a Shortcuts window come next.
