---
title: "Authored and live trees"
description: "A tween tree as an authored value in a component field and as a live tree of pooled nodes, how it runs, and how a plugin adds a node type"
weight: 10
tags: ["tween", "concepts"]
---

A tween tree has two forms, one for each job. The code is `tweens.odin`, `runtime.odin` and `runs.odin`.

## Authored

- A tree is one guid-tagged JSON value, `tween.Authored`, kept in component fields such as `animations: [dynamic]tween.Authored`. Saving, undo, prefab overrides and copy and paste treat it as a plain value.
- Children nest in the parent's `"children"` array.
- A node type the installed plugins do not register stays in the value untouched, like an unknown component.
- Object references inside a value remap on copy and paste through the engine's ref-remap hook, since the typed walk cannot see into JSON.

## Live

- `tween.run` builds the value into per-type pools and returns the run's handle ([Runs](Runs.md)). A composite holds its children as `Node_Handle` arrays, dispatch is an index into the registered type table, and a run that ends frees its tree.
- `tween.register(key, &a)` stores a tree under a name, and `tween.run(key, ctx)` runs a fresh copy of it each time.
- A run with a node type that is not registered does not start, since a half-built sequence would misbehave without a word. `tween.run` returns the zero handle then.

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

Any plugin adds node types with no code generation. There are two shapes.

### A value node

A value node moves one value from where it is to an authored end. The runtime owns its delay, time, easing and cycles, so the node only captures a start and writes the value at a factor.

```odin
import tween "moonhug:packages/tween"

@(typ_guid={guid = "..."})
TweenFadeTo :: struct {
	using base: tween.Tween `inline:""`,
	using anim: tween.Tween_Anim `inline:""`,
	alpha:    f32,
	duration: f32,

	from: f32 `json:"-"`,
}

type_cleanup_TweenFadeTo :: proc(self: ^TweenFadeTo) {
	tween.type_cleanup_Tween_Anim(&self.anim)
	self^ = {}
}

@(phase={key=SerializationInit, order=2})
my_tween_nodes_init :: proc() {
	tween.register_tween(TweenFadeTo, begin_TweenFadeTo, apply_TweenFadeTo)
}

begin_TweenFadeTo :: proc(self: ^TweenFadeTo, ctx: tween.TweenContext) -> bool {
	self.from = current_alpha(ctx.subject)
	return true // false ends the node: the target is gone
}

apply_TweenFadeTo :: proc(self: ^TweenFadeTo, t: f32, ctx: tween.TweenContext) {
	set_alpha(ctx.subject, self.from + (self.alpha - self.from) * t)
}
```

- The struct embeds `tween.Tween` first, as `using base`, and `tween.Tween_Anim`, and has a `duration: f32` field.
- `begin` runs once, after the node's delay. `apply` runs every tick with the factor: 0 is the start and 1 is the end.
- The factor leaves 0..1 with the `Back` and `Elastic` eases and in `Incremental` cycles, so `apply` does not clamp it.
- `Tween_Anim` owns its curve's keys, so the node declares a `type_cleanup_<Name>` that calls `type_cleanup_Tween_Anim`.
- `plugins/plugin_example/tween_spinner.odin` is the reference.

### A node that ticks itself

A composite, or a step with its own idea of time, registers a tick proc.

```odin
@(typ_guid={guid = "..."})
MyStep :: struct {
	using base: tween.Tween `inline:""`,
	// a composite declares: children: [dynamic]tween.Node_Handle `json:"-"`
}

@(phase={key=SerializationInit, order=2})
my_step_init :: proc() {
	tween.register_node(MyStep, tick_MyStep)
}

tick_MyStep :: proc(self: ^MyStep, dt: f32, ctx: tween.TweenContext) -> tween.Status {
	if tween.has_delay(&self.base, dt) do return .Running
	return .Done
}
```

- A composite ticks its children with `tween.tick_node(h, dt, ctx)` and reads their status with `tween.node_base(h)`.
- A composite passes `.Sum` or `.Longest` as `register_node`'s third argument when its length follows from its children, which gives its runs a progress.

### Rules for both

- Runtime-only fields carry `json:"-"`, so values never store them.
- A node that owns memory besides its children declares `type_cleanup_<Name>`, which `node_destroy` runs.
- The type guid is the saved identity. Never change it.
- The stock nodes register the same way.
