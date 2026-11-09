---
title: "Input Actions"
description: "An asset of mapping contexts, each with actions and the key mappings that drive them"
weight: 10
tags: ["input", "assets"]
---

An asset of mapping contexts. Assets, Create, Input Actions makes one, and the Input project setting picks the one the game uses.

## Structure

- **A mapping context** has a name, a priority, a Consume Input mode and a list of actions. Player, Vehicle, Gun and Menu are contexts ([The context stack](../concepts/ContextStack.md)).
- **An action** has a name, a value type, a Consume flag, a dead zone and key mappings. The value types are Digital, a button, Axis1D and Axis2D.
- **A key mapping** names a key and a modifier, and has a `scalar` that multiplies its value. The modifier is Whole, or Positive and Negative for an Axis1D, or Up, Down, Left and Right for an Axis2D, so four keys compose into a stick.

## Key names

Keys are named `device:name`:

| Device | Keys |
|---|---|
| `key:` | SDL scancode names, physical positions: `key:W`, `key:SPACE`, `key:LEFT_SHIFT`. |
| `mouse:` | `mouse:Left`, `mouse:Right`, `mouse:Middle`, `mouse:Delta`, an Axis2D in pixels this frame, and `mouse:Wheel`, an Axis1D. |
| `pad:` | SDL gamepad button names: `pad:SOUTH`, `pad:NORTH`, `pad:DPAD_UP`, `pad:LEFT_SHOULDER`. `pad:LEFT_STICK` and `pad:RIGHT_STICK` are Axis2D, up positive. `pad:LEFTX`, `pad:RIGHTY`, `pad:LEFT_TRIGGER` and `pad:RIGHT_TRIGGER` are Axis1D. |

## In the editor

- The inspector has one section per context, with its name, priority and Consume Input mode, and a table with one row per key mapping: the action's name, value type, Consume flag and dead zone on its first row, then the mapping's key, modifier and scalar.
- A row under each action adds a mapping, moves the action up or down, and removes it. Each mapping row removes itself, and buttons add actions and contexts.
- The key cell opens a picker: a search over every key by device, and Listen, which takes the next key, mouse button or gamepad button pressed.
- A cell edit is one undo step of that value. An add or a remove is one step of the asset.
- The open asset reaches the running game every frame, saved or not: an edit shows in the debug window at once, and pushed contexts stay pushed. A save, or a change of the file on disk, rebuilds the runtime the same way.
