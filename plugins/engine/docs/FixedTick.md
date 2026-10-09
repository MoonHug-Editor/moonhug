---
title: "Fixed Tick"
description: "Fixed-rate simulation update with one project tick rate, per-proc order and divisor, and a code-side rate override"
weight: 70
tags: ["components", "engine"]
---

Fixed-rate simulation update. ONE project tick rate (default 60 Hz,
`plugins/engine/fixed_tick.odin`, configurable via the Time section of Project
Settings — `engine.time_settings`) — no per-system rates; coarse systems use
the divisor instead. 60 rather than Unity's 50: without view interpolation it
aligns 1:1 with 60 Hz displays, so fixed-stepped motion shows no cadence
judder. `fixed_set_rate` is a code-side override that wins over the setting
until reset to 0.

```odin
@(fixed_update={order=10})            // every tick, fixed_dt
physics_step :: proc(fixed_dt: f32) {}

@(fixed_update={order=20, divisor=4}) // every 4th tick, fixed_dt * 4
ai_tick :: proc(dt: f32) {}

@(update={order=1})                   // stays PER-FRAME: view-side work
tween_tick :: proc(dt: f32) {}

@(late_update)                        // after every @(update), before rendering
camera_follow :: proc(dt: f32) {}

@(fixed_update={component=Spinner})   // per item: once per enabled Spinner
fixed_update_Spinner :: proc(dt: f32, s: ^Spinner) {}
```

- Works in any package's runtime code, the app included (docs/core/Plugins.md) —
  prebuild bakes every subscriber into `__fixed_update` in
  `update_generated.odin`, interleaved by order.
- `@(late_update)` runs after every `@(update)` proc, the last stage before the frame renders, for work that reads the frame's results: a camera following its target, UI laid out from final transforms. It takes `order` and `component` like `@(update)`.
- Two shapes, on `@(update)`, `@(late_update)` and `@(fixed_update)`. A system, `proc(dt)`, loops over what it updates itself, for work across several pools or none (physics, destroy pass, audio). A per-item proc names a `@(component)` or `@(poolable)` type with `component = T` and takes `proc(dt, c: ^T)`. By convention it is named `update_<T>` or `fixed_update_<T>` after its attribute. Prebuild writes its loop as `__<proc>` in `update_generated.odin`: every alive instance in pool order, skipping disabled components (a poolable has no `enabled`). The loop fetches nothing else, the proc reads its owner's Transform itself when it needs it. A per-item proc sorts by `order` like a system, default 0.
- `engine.frame_tick(__ticks, dt)` is the frame's simulation, written once: the accumulator consumes the frame dt, runs 0..k fixed ticks (latching input before each), carries the remainder, then runs the frame tick. The game's loop calls it, and so does the editor's Simulate through the generated `__frame_tick`, with `step = true` for one fixed tick and one frame tick. After a stall at most
  `FIXED_MAX_CATCHUP_TICKS` catch-up ticks run and the rest of the backlog is
  DROPPED (the sim jumps instead of spiraling).
- `engine.fixed_tick_index()` is the running tick counter,
  `engine.fixed_dt()` the tick delta.

## Input latching

Per-frame edges (`input.key_pressed`) can fall between fixed ticks. Fixed
code uses the `_fixed` variants — `input.key_down_fixed`,
`input.key_pressed_fixed`, `input.mouse_pressed_fixed`, … — whose edges
accumulate across frames and are consumed once per tick
(`input.fixed_latch`, called by the app loop). A press shorter than a
tick still registers on the next tick; a tap that started and ended between
ticks reads as down for one tick.

## Units and time

1 world unit = 1 meter (= 100 px on screen via sprite import scale, when
that lands). Velocities in units/second, `fixed_dt` in seconds.

## Deferred

View interpolation between ticks — the 60 Hz default makes it a non-issue on
common displays; needed if the rate ever drops below refresh.
