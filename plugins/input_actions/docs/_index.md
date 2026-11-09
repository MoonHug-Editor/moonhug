---
title: "input_actions"
description: "Named actions over keys, mouse and gamepad: an Input Actions asset of mapping contexts, a priority stack of contexts, and per-frame and per-tick values"
tags: ["input", "plugin"]
---

Game code reads actions, not keys: `pressed(jump)`, `value2(move)`. An Input Actions asset says which keys drive each action, so a game rebinds without a code change, and a gamepad is one more mapping, not another code path. Actions live in mapping contexts, which the game pushes on a stack: Player at start, Vehicle in a car, Menu while a menu is open.

## What it adds

**Assets**

- [Input Actions](assets/InputActions.md): mapping contexts of actions and their key mappings, edited in a table inspector.

**Windows**

- [Input Actions](windows/InputActionsWindow.md): the pushed contexts and every action's live state, with buttons to push and pop contexts.

**Concepts**

- [Reading actions](concepts/ReadingActions.md): resolving names, the frame's and the tick's values.
- [The context stack](concepts/ContextStack.md): which context answers for a key, and what it takes from the ones below.

[Roadmap](Roadmap.md): what is not built yet.

## What it needs

- The engine plugin and its input library, `moonhug:libs/input`. The first connected gamepad is read, and the next one when it disconnects.

## Project settings

Edit, Project Settings, Input. Saved in `ProjectSettings/input.json`.

| Setting | Default | What it does |
|---|---|---|
| `actions` | none | The Input Actions asset the game uses. Its foldout draws the asset's inspector in place, so the mappings are editable from Project Settings. |

## Quick start

1. Assets, Create, Input Actions, and pick it in the Input project setting.
2. Add a context named Player, an action Jump with the key `key:SPACE`, and an Axis2D action Move with W, A, S and D on Up, Left, Down and Right.
3. In code, resolve the names at start, push Player, and read the actions ([Reading actions](concepts/ReadingActions.md)).

## Extending

The plugin declares no attributes and has no registries. `debug_rows()` returns the data behind the debug window, for a game's own overlay.

## Limits

- One player and one gamepad at a time.
- No hold or tap triggers, no control schemes, no runtime rebinding ([Roadmap](Roadmap.md)).

## Reference

- [API reference](/docs/reference/packages/input_actions/input_actions.md) of the `input_actions` package.
