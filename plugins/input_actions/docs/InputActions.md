---
title: "Input Actions"
description: "Named actions over keys, mouse and gamepad: an Input Actions asset of mapping contexts with key mappings, a priority stack of contexts that consume the keys below them, per-frame and per-tick values"
weight: 20
tags: ["input", "plugins"]
path: plugins/input_actions
---

Game code reads actions, not keys: `pressed(jump)`, `value2(move)`. An Input Actions asset says which keys drive each action, so a game rebinds without a code change and a gamepad is one more mapping, not another code path. The plugin is `plugins/input_actions`, package `input_actions`. The vocabulary follows Unreal's Enhanced Input: mapping contexts, actions with a value type, key mappings with modifiers.

## The asset

An Input Actions asset (`Input_Actions`, Assets ▸ Create ▸ Input Actions) holds mapping contexts. The Input project setting (Edit ▸ Project Settings… ▸ Input, `ProjectSettings/input.json`) names the asset the game uses. Its row has the foldout arrow (the `expand` field tag), which draws the asset's inspector in place, so the mappings can be edited from Project Settings.

- A mapping context (`Mapping_Context`) has a name, a priority, a Consume Input mode and a list of actions. Player, Vehicle, Gun, Menu are contexts.
- An action (`Action`) has a name, a value type (`Digital`, `Axis1D`, `Axis2D`), a Consume flag, a dead zone and key mappings.
- A key mapping (`Key_Mapping`) names a key and a modifier: `Whole`, or `Positive` / `Negative` for an Axis1D, `Up` / `Down` / `Left` / `Right` for an Axis2D, so four keys compose into a stick. `scalar` multiplies the value.

Key names are `device:name` (`Key_Name`):

- `key:W`, `key:SPACE`, `key:LEFT_SHIFT`: SDL scancode names, physical positions.
- `mouse:Left`, `mouse:Right`, `mouse:Middle`, `mouse:Delta` (Axis2D, pixels this frame), `mouse:Wheel` (Axis1D).
- `pad:SOUTH`, `pad:NORTH`, `pad:DPAD_UP`, `pad:LEFT_SHOULDER` …: SDL gamepad button names. `pad:LEFT_STICK` and `pad:RIGHT_STICK` are Axis2D (up positive), `pad:LEFTX`, `pad:RIGHTY`, `pad:LEFT_TRIGGER`, `pad:RIGHT_TRIGGER` are an Axis1D.

The first connected gamepad is read, the next one when it goes (`moonhug:libs/input`).

## The inspector

`editor/asset_inspector.odin` draws one section per mapping context with its name, priority and Consume Input mode, and a table with a row per key mapping: the action's name, value type, Consume flag and dead zone on its first row, then the mapping's key, modifier and scalar. A row under each action adds a mapping, moves the action up or down and removes it, each mapping row removes itself, and buttons add actions and contexts.

- A cell edit is one undo step of that value. An add or a remove is one step of the asset.
- The open document reaches the running game every frame, saved or not: an edit shows in the debug window at once, and the pushed contexts stay pushed. A save, or a change of the file on disk, rebuilds the runtime the same way.
- The key cell is a button that opens a picker: a search over every key by device, and Listen, which takes the next key, mouse button or gamepad button pressed.

## Reading actions

Resolve the names once, at startup, then read every frame or tick:

```odin
jump, move: input_actions.Action_Id

@(phase={key=EngineInit, order=100})
my_init :: proc() {
	jump = input_actions.action_id("Player", "Jump")
	move = input_actions.action_id("Player", "Move")
	input_actions.context_push("Player")
}

@(comp_fixed_update={component=Hero})
comp_fixed_update_Hero :: proc(dt: f32, h: ^Hero) {
	if input_actions.pressed_fixed(jump) do hero_jump(h)
	dir := input_actions.value2_fixed(move)
}
```

- `down`, `pressed`, `released`, `value`, `value2` are the frame's values, resolved before every `@(update)`.
- The `_fixed` twins are the tick's, resolved before every `@(fixed_update)` from the input library's fixed view, so a tap between two ticks still reads as one press.
- `pressed` and `released` are edges of the action's own down state. A Digital action is down while any mapping is, an axis while its value is not zero.
- `action_id` panics on a name the asset lacks, so a typo stops the game at launch.

## The context stack

Nothing resolves until a context is pushed. `context_push(name)` and `context_pop(name)` keep a stack ordered by priority, a later push above an earlier one of the same priority. The game pushes Player at start, Vehicle when the player enters a car, Menu when a menu opens, and pops them on the way out. Nothing re-enables the context below: it was never disabled.

For each key the highest pushed context that maps it answers. What a context takes from the contexts below it is its Consume Input mode:

- `All`: every key. A Menu context on top blocks all gameplay input.
- `Listed`: only the keys of its actions marked Consume. A Gun context pushed over Player takes Fire's key and leaves movement to Player.

A popped context's actions read as released and zero.

## The debug window

Window ▸ Input ▸ Input Actions (`editor/debug_window.odin`) names the Input setting's asset with a Select button that selects it for editing, lists every mapping context of the asset with a Push or Pop button, so a stack can be tried without the game code that would push it, then the pushed contexts from the top down and, under each, their actions with their live state (pressed, down, released), value and keys. An action whose keys a context above consumes shows greyed out: it cannot answer. The values are the running game's, so the window fills while the game runs. `debug_rows()` is the data behind it.

## Not yet

A generated enum of the actions, control schemes, runtime rebinding with an override file, touch and on-screen controls, several players with their own devices, hold and tap triggers.
