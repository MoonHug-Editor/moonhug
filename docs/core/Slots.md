---
title: "Slots"
description: "A field that takes its value inline or from a dictionary the game fills: the slot and its inline field, dictionaries and their chain, declared entries, and the inspector's one row for both"
weight: 31
tags: ["slots", "libs", "inspector"]
path: general/architecture
---

A slot is a field that takes its value inline, set in the inspector, or from a dictionary the game fills. A programmer publishes named values, and whoever sets up a component decides per field whether to type a value or connect it to one of them. The library is `moonhug/libs/slots`.

```odin
import "moonhug:libs/slots"

Mover :: struct {
	using base: engine.CompData `inspect:"-"`,
	speed:  slots.Slot,            // what code and the inspector see
	_speed: f32 `inspect:"-"`,     // the inline value
}

speed := slots.get(m.speed, m._speed, slots.global())
```

## The slot and its inline field

- A slot is the name of a dictionary entry, or nothing (`slots.INLINE`).
- The inline value is a field of its own, named as the slot with `_` in front and tagged `inspect:"-"`. It has the value's type, so any type works with no extra declaration.
- Code reads through `slots.get(slot, inline, dict)`. The underscore says the inline field is not the value: reading it directly ignores a connection.
- The prebuild checks the pair: a slot without its `_name` field, or an inline field without `inspect:"-"`, stops the build.
- A slot is plain data and saves as the entry's key, an empty string when it is not connected. The key of an entry code fills is its name. The key of a [Blackboard](/plugins/blackboard/docs/components/Blackboard.md)'s entry is its id, written `#0b160001`, which stays when the entry is renamed.

## Reading

`slots.get` returns:

- the inline value, when the slot is not connected,
- the entry's value, when a dictionary in the chain has it,
- the inline value, when none has it. An edit-mode preview, where no game code runs, shows the inline value.

An entry of another type than the inline field's is reported once and the inline value is used. `slots.lookup(slot, T, dict)` says whether the entry was there.

`get` reads when it is called. Code that wants a value that follows the game reads every frame, and code that wants it fixed reads once.

## Dictionaries

```odin
d: slots.Dict
slots.set(&d, "speed", f32(3))                  // a value
slots.set_proc(&d, "target", [3]f32, read, me)  // computed on every read
d.parent = slots.global()                       // looked in next
defer slots.destroy(&d)
```

- An entry is a value or a proc that computes it on every read.
- A value is copied in as bytes, `slots.MAX_VALUE_SIZE` at most, so it is plain data: a number, a vector, a color, a handle, a reference.
- A dictionary without the entry asks its `parent`, and so on along the chain.
- `slots.global()` is one dictionary for the whole game, for values many readers share. A dictionary of the caller's own puts it last in its chain.
- A dictionary is used from one thread.

## An object's dictionary

```odin
speed := slots.get(m.speed, m._speed, slots.scope_of(m.owner))
```

A component reads its slots from `slots.scope_of(owner)`, the dictionary of the object it is on.

- A package installs how that dictionary is found, a scope (`slots.scope_install`). The [blackboard plugin](/plugins/blackboard/docs/_index.md) installs one: the nearest Blackboard component on the object or above it, then the ones further up, then the game-wide dictionary.
- Without a scope, or for an object the scope has nothing for, `scope_of` is the game-wide dictionary. So a reader never depends on the package that installs the scope.
- `slots.scope_entries(owner, T)` lists what the scope offers an object, for the inspector: each entry's slot, the name it is shown by, and where it comes from. `slots.label(owner, slot)` is the name a connection is shown by now.

## Declared entries

```odin
slots.declare("speed", f32, "Units per second of the level's conveyor")
```

Declaring an entry says its name and type exist. It makes no value. The inspector offers a slot the declared entries of its inline field's type, so an entry can be connected before the game runs. Declare from an `@(init)` proc, so the editor has the list in edit mode.

## In the inspector

A slot and its inline field are one row under the slot's name:

- Not connected, the row is the inline field's: its own drawer and decorators, its undo and its prefab override.
- Connected, the row reads `from <entry>`, the entry's name as it is now.
- The link button at the end of the label column lists what the slot can take its value from: the inline value, the entries of the type the scope offers the object, such as those of the Blackboards above it, and every declared entry of the type. Picking one is one undo step, applied to every selected object.
- A connection to an entry nothing offers, such as one of a Blackboard that was removed, is listed as not offered, so it can be seen and replaced.

## Example

`SlotExample` in the app plugin (`plugins/app/component_SlotExample.odin`, Component > Demo > SlotExample) has an `offset` and a `size` slot, read from its object's dictionary. It declares and fills the entries `demo_bob`, `demo_pulse` and `demo_double` in the game-wide dictionary.

The scene `plugins/app/assets/demo_slots/demo_slots.scene` shows it four ways: a cube with typed values, one connected to the game's entries, and two squads whose cubes take `big` and `lift` from their squad's Blackboard, one with a nearer Blackboard that changes `big` for the cube under it.
