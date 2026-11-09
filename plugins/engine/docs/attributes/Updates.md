---
title: "Updates"
description: "@(update), @(fixed_update) and @(late_update), as systems or per component: the procs that run every frame or every fixed tick"
weight: 30
tags: ["engine", "attributes"]
path: engine/attributes
---

Six attributes run code every frame or every fixed tick. Each stage has two shapes: a system that loops over what it updates itself, and a per-component proc that the engine calls for every enabled instance of one type.

| Stage | System | Per component | Runs |
|---|---|---|---|
| Fixed | `@(fixed_update)` | `@(comp_fixed_update)` | On the fixed simulation tick, with the fixed step in seconds. Simulation and gameplay go here. |
| Frame | `@(update)` | `@(comp_update)` | Every frame, with the frame's delta time. Tweens, cameras and UI go here. |
| Late | `@(late_update)` | `@(comp_late_update)` | Every frame after every frame proc, the last stage before rendering. A camera that follows its target goes here. |

## Example

```odin
@(comp_fixed_update={order=-50, component=Lifetime})
comp_fixed_update_Lifetime :: proc(dt: f32, lt: ^Lifetime) {
    lt.time_spent += dt
    if lt.time_spent >= lt.duration do engine.transform_destroy_later(lt.owner)
}

@(update={order=3})
particles_tick :: proc(dt: f32) {
    // loops over every particle system itself
}
```

## Rules

- A system is `proc(dt: f32)`. A per-component proc is `proc(dt: f32, c: ^T)` named `comp_<stage>_T`, with `component = T` naming a `@(component)` or `@(poolable)` type.
- `order` sorts procs across every package and both shapes of a stage. Lower runs first, and 0 is the default.
- `divisor = N` on a fixed proc runs it on every Nth tick only, with the step times N. `@(fixed_update={order=20, divisor=4})` runs every 4th tick.
- The tick rate is the Time project setting, 60 by default ([Fixed tick](../FixedTick.md)).
- Code inside a loop over a pool destroys with `transform_destroy_later`, which queues the object until the loop is over.

## Reference

- [@(update)](/docs/reference/attributes/engine/update.md), [@(comp_update)](/docs/reference/attributes/engine/comp_update.md), [@(fixed_update)](/docs/reference/attributes/engine/fixed_update.md), [@(comp_fixed_update)](/docs/reference/attributes/engine/comp_fixed_update.md), [@(late_update)](/docs/reference/attributes/engine/late_update.md), [@(comp_late_update)](/docs/reference/attributes/engine/comp_late_update.md)
- [Fixed tick](../FixedTick.md) and [Script execution order](../ScriptExecutionOrder.md).
