---
title: "blackboard"
description: "A component that holds named values, authored in the inspector, for the slots of its object and the objects under it"
tags: ["blackboard", "slots", "plugin"]
---

The blackboard plugin holds named values on objects. A slot field on any component of the object, or of an object under it, can take its value from one of them, picked in the inspector. Game code can change a value while the game runs.

## What it adds

**Components**

- [Blackboard](components/Blackboard.md): a list of entries, each a name, a type and a value.

## What it needs

- The engine plugin.
- Slots are the shell's `moonhug/libs/slots` library ([Slots](/docs/core/Slots.md)), which every package has.

## Quick start

1. Add Component, Blackboard/Blackboard on an object with children. Open `entries`, press Add, name the entry `big`, keep its type Number and set it to 2.
2. On a child, add Component, Demo/SlotExample (the app plugin).
3. Click the link button on the child's `size` row and pick `big`. The row reads `from big`.
4. Press Play: the child is twice its size. Change `big` on the Blackboard and it follows.

## Extending

The plugin declares no attributes and has no registries.

- A component reads its slots with `slots.get(slot, inline, slots.scope_of(owner))` and needs no import of this plugin. Without the plugin `scope_of` is the game-wide dictionary.
- Game code sets a value with `blackboard.set(object, name, value)` and takes it back with `blackboard.unset(object, name)`.

## Limits

- A slot connects by name. Renaming an entry leaves the slots connected to the old name on their inline value, and their link button lists the old name as not offered.
- A prefab instance that changes one entry overrides the whole `entries` list.
- A value set from code is not saved, and lasts as long as the component.
- Blackboards are not assets: a list of entries cannot be shared between objects that are not under one Blackboard.

## Reference

- [API reference](/docs/reference/packages/blackboard/blackboard.md) of the `blackboard` package.
- Sample: `demo_slots.scene` in the app plugin (`plugins/app/assets/demo_slots`): two squads of cubes under Blackboards with other values, and a nearer Blackboard that changes one entry.
