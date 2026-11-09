---
title: "Physics callbacks"
description: "@(comp_on_collision_enter), exit, and the trigger pair: a component's procs when its object's colliders start or stop touching"
weight: 40
tags: ["engine", "attributes", "physics"]
path: engine/attributes
---

Four attributes run a component's proc when a collider of its object starts or stops touching another. The engine declares them, and the physics2d and physics3d plugins call them.

| Attribute | Runs |
|---|---|
| `@(comp_on_collision_enter)` | A collider of the object starts touching another collider. |
| `@(comp_on_collision_exit)` | It stops touching it. |
| `@(comp_on_trigger_enter)` | A trigger of the object starts overlapping a collider, or a collider of the object enters a trigger. |
| `@(comp_on_trigger_exit)` | The overlap ends. |

## Example

```odin
@(comp_on_trigger_enter={component=Pickup})
comp_on_trigger_enter_Pickup :: proc(c: ^Pickup, other: engine.Transform_Handle) {
    engine.transform_destroy(c.owner)
}
```

## Rules

- `component = T` names a `@(component)` type of the same package. The proc is `proc(c: ^T, other: Transform_Handle)` named `comp_<attribute>_T`, and `other` is the other shape's object.
- The physics plugin calls them after the solver step, in the same fixed tick. A callback may destroy, spawn or push bodies freely.
- A callback runs on the components of the shape's own object only, not on its parents or children. Both objects of a contact get their callbacks.
- There is no stay callback. A component that needs one keeps its own set from enter and exit.
- They run only while the game runs. A contact between two objects with no callbacks costs two bit tests.

## Reference

- [@(comp_on_collision_enter)](/docs/reference/attributes/engine/comp_on_collision_enter.md), [@(comp_on_collision_exit)](/docs/reference/attributes/engine/comp_on_collision_exit.md), [@(comp_on_trigger_enter)](/docs/reference/attributes/engine/comp_on_trigger_enter.md), [@(comp_on_trigger_exit)](/docs/reference/attributes/engine/comp_on_trigger_exit.md)
- [Component data](../Components.md), "Physics contact hooks".
