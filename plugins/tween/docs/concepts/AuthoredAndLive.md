---
title: "Authored and live trees"
description: "A tween tree as an authored value in a component field and as a live tree of pooled nodes, how it runs, and how a plugin adds a node type"
weight: 10
tags: ["tween", "concepts"]
---

A tween tree has two forms, one for each job. The code is `tweens.odin` and `runtime.odin`.

## Authored

- A tree is one guid-tagged JSON value, `tween.Authored`, kept in component fields such as `animations: [dynamic]tween.Authored`. Saving, undo, prefab overrides and copy and paste treat it as a plain value.
- Children nest in the parent's `"children"` array.
- A node type the installed plugins do not register stays in the value untouched, like an unknown component.
- Object references inside a value remap on copy and paste through the engine's ref-remap hook, since the typed walk cannot see into JSON.

## Live

- `tween_run` builds the value into per-type pools. A composite holds its children as `Node_Handle` arrays, dispatch is an index into the registered type table, and a finished run frees its tree.
- `tween_register(key, &a)` stores a tree under a name, and `tween_run(key, ctx)` runs a fresh copy of it each time.
- `tween_tick_running(dt, ctx)` ticks every running tree, once per frame.
- A run with a node type that is not registered fails whole, since a half-built sequence would misbehave without a word.

## Building trees in code

```odin
a, ok := tween.authored_make(typeid_of(tween.Sequence))
child, _ := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
tween.authored_add_child(&a.value, child)                  // the child moves in
tween.authored_remove_child(&a.value, 0)                   // and is freed
tween.authored_retype(&a.value, typeid_of(tween.Parallel))

tween.registered_node_types()                              // every registered type
tween.node_type_has_children(tid)                          // composite or leaf
```

`authored_make` fails for a type that is not registered, and `authored_add_child` fails on a leaf. `authored_retype` resets every field to the new type's defaults and keeps the children when the new type is a composite.

## Adding a node type

Any plugin adds node types, composites included, with no code generation:

```odin
import tween "moonhug:packages/tween"

@(typ_guid={guid = "..."})
MyShake :: struct {
	using base: tween.Tween `inline:""`,
	strength: f32,
	// a composite declares: children: [dynamic]tween.Node_Handle `json:"-"`
}

@(phase={key=SerializationInit, order=2})
my_tween_nodes_init :: proc() {
	tween.register_node(MyShake, tick_MyShake)
}

tick_MyShake :: proc(self: ^MyShake, dt: f32, ctx: tween.TweenContext) -> tween.Status {
	return .Done
}
```

- The struct embeds `tween.Tween` first, as `using base`.
- Runtime-only fields carry `json:"-"`, so values never store them.
- A node that owns memory besides its children declares `type_cleanup_<Name>`, which `node_destroy` runs.
- The type guid is the saved identity. Never change it.
- A composite ticks its children with `tween.tick_node(h, dt, ctx)` and reads their status with `tween.node_base(h)`.
- The stock nodes register the same way.
