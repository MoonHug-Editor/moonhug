---
title: "Blackboard"
description: "Holds named values that the slots of its object and the objects under it can take their value from"
weight: 10
tags: ["blackboard", "slots", "components"]
---

Holds named values that the slots of its object and the objects under it can take their value from. A [slot](/docs/core/Slots.md) is a field set in the inspector or connected to a named entry.

## Example

```
Enemy          Blackboard:  tint = red,  speed = 2
├── Body       Glow:   color  from tint
└── Legs       Mover:  speed  from speed
```

Changing `tint` on the Blackboard changes every field connected to it under Enemy. A second enemy has a Blackboard of its own, so its own values.

## Properties

| Field | Default | What it does |
|---|---|---|
| `entries` | empty | The entries. Each is drawn on one line: its name, its type, its value. |

An entry's type is one of:

| Type | Value |
|---|---|
| Number | `f32` |
| Integer | `i32` |
| Flag | `bool` |
| Vector2, Vector3 | `[2]f32`, `[3]f32` |
| Color | `[4]f32` |
| Object | an object of the scene |
| Asset | an asset or a sub-asset |

## Behavior

- A slot takes an entry from the nearest Blackboard on its object or above it, then from the Blackboards further up, then from the game-wide dictionary. When none has the entry, the slot uses its inline value.
- A slot connects to an entry's id, not its name. The id is given when the entry is made and never changes, so renaming an entry breaks no connection: the slot's row shows the name the entry has now.
- A copy of a Blackboard keeps its entries' ids, so a duplicated object's Blackboard answers the same slots with its own values.
- A nearer Blackboard changes an entry for the objects under it with an entry of the same id, made with Override Entry.
- An entry made anew is another entry, whatever its name: slots connected to an older entry of that name do not take it.
- An entry fits a slot when its type is the slot's inline field's type. One of another type is reported once and the inline value is used.
- An edit of an entry shows at the next read, in edit mode too.
- An entry without a name is not offered to slots.

## In the editor

- A slot's link button lists the entries of its type from the Blackboards above the object, nearest first, each with the name of the object its Blackboard is on.
- A connected slot's row shows the entry's value, read-only, and in its label column the object and the entry: `Squad B: lift`. A click on it pings that object, a double click selects it.
- Each of an entry's name, type and value is its own undo step.
- Override Entry, under the list, shows when a Blackboard above has entries this one has none for. Picking one adds an entry with its id, name, type and value, to change here.
- An entry gets its id in the step that adds it, so an undo takes both and a redo brings the same id back.

## From code

```odin
import blackboard "moonhug:packages/blackboard"

hp, ok := blackboard.get(enemy, "hp", f32)       // what a reader on enemy gets
blackboard.set(enemy, "speed", f32(0))           // the legs stop
blackboard.unset(enemy, "speed")                 // the authored value again
slots.write(m.hp, f32(4), slots.scope_of(m.owner))  // through a slot
```

- `get` returns the value a reader on the object gets, and false when nothing has the entry or it holds another type.
- `set` reaches the nearest Blackboard on the object or above it, and returns false when there is none.
- Code names the entry, and the name finds the entry a reader on the object would get. A name no entry has is an entry of its own, keyed by the name.
- The value goes on top of the authored entry. It is not saved, and it lasts as long as the component.
- `set` writes on the nearest Blackboard, so it changes the entry for the objects under that Blackboard only. A write through a slot (`slots.write`) goes to the Blackboard that holds the entry, so every reader of the entry gets it: a medic writes the squad's `hp` and the squad's health bar reads it. Under a Blackboard with an override of the entry, the write goes to the override.
- `blackboard.entry_add(b, name)` makes an entry with a new id, and `blackboard.entry_override(b, from)` one that stands in for an entry above.
- A reader needs nothing from this package: `slots.get(slot, inline, slots.scope_of(owner))`.

## Limits

- A prefab instance that changes one entry overrides the whole list.
- Two entries of one Blackboard with the same name are two entries. The picker lists both by that name.
- An entry written by hand without an id is keyed by its name, as an entry code fills is.

## See also

- [Slots](/docs/core/Slots.md), the fields that connect to entries, and dictionaries.
