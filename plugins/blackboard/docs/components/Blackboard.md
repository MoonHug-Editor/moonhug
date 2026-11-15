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
- A nearer Blackboard's entry of a name hides the ones above it.
- An entry fits a slot when its type is the slot's inline field's type. One of another type is reported once and the inline value is used.
- An edit of an entry shows at the next read, in edit mode too.
- An entry without a name is ignored.

## In the editor

- A slot's link button lists the entries of its type from the Blackboards above the object, nearest first, each with the name of the object its Blackboard is on.
- Each of an entry's name, type and value is its own undo step.

## From code

```odin
import blackboard "moonhug:packages/blackboard"

blackboard.set(enemy, "speed", f32(0))   // the legs stop
blackboard.unset(enemy, "speed")         // the authored value again
```

- `set` reaches the nearest Blackboard on the object or above it, and returns false when there is none.
- The value goes on top of the authored entry. It is not saved, and it lasts as long as the component.
- A reader needs nothing from this package: `slots.get(slot, inline, slots.scope_of(owner))`.

## Limits

- Renaming an entry does not rename the connections to it.
- A prefab instance that changes one entry overrides the whole list.

## See also

- [Slots](/docs/core/Slots.md), the fields that connect to entries, and dictionaries.
