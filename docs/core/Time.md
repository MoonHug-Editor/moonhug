---
title: "Time"
description: "The game's time: delta time, the time scale, unscaled and fixed time, and the clocks timed systems run on, built-in and added by packages"
weight: 30
tags: ["time", "libs"]
path: general/architecture
---

The game's time, its scale, and the clocks that timed systems such as tweens run on. It is the `time` package in `moonhug/libs/time`.

```odin
import "moonhug:libs/time"
```

- The folder gives the import its name, so calls read `time.delta_time()`.
- The package itself is `mh_time`: a build allows one package named `time`, and Odin's own library has it.
- A file that also needs Odin's time package names one of the two: `import core_time "core:time"`.

## Reading time

Two procs read time, and both take the clock to read. `Update` is the default.

```odin
dt := time.delta_time()             // this frame's step in seconds, scaled
time.now()                          // seconds since Play started, scaled

real := time.delta_time(.Unscaled)  // this frame's real step
time.now(.Unscaled)                 // real seconds since Play started

time.delta_time(.Fixed)             // the step of one fixed tick
time.now(.Fixed)                    // seconds the fixed tick has simulated

time.frame_count()                  // frames since Play started
```

- Inside an `@(update)` proc, `time.delta_time()` is that proc's `dt`.
- Everything starts from 0 when Play starts.

## The time scale

```odin
time.set_time_scale(0.25)   // slow motion
time.set_time_scale(0)      // hold the game
time.set_time_scale(1)      // real speed
```

- The time scale is one number for the whole game.
- It scales the delta time that `@(update)` and `@(late_update)` procs get.
- It scales how fast fixed ticks come. At 0.5 a fixed tick runs half as often, still with the full fixed step, so the simulation stays stable.
- At 0 no fixed tick runs and the frame's delta time is 0.
- The `Unscaled` clock ignores it. A menu that has to move while the game is held reads `time.delta_time(.Unscaled)`.
- `time.set_paused(true)` holds the game the same way and keeps the scale for later.
- The editor's Step button runs one fixed tick and one frame whatever the scale is.

## Clocks

`time.Clock` names a timeline.

| Clock | Advances | By |
|---|---|---|
| `Update` | every frame | the scaled delta time |
| `Fixed` | every fixed tick | the fixed step |
| `Unscaled` | every frame | the real delta time |

A timed system takes a clock where its time is a choice: `tween.position(door, to, 0.3, opt = {clock = .Unscaled})`.

What reads the clocks today:

- Tweens tick on the clock their run names.
- UI button transitions fade on `Unscaled`, so a menu works while the game is held.
- Timed gizmos on the game clock expire by `time.now(.Fixed)`.

## Adding a clock

A package adds clocks with a `Clock_Extra` enum of its own. Prebuild lists its values after the built-in ones in the generated `time.Clock` enum, so every package names them the same way.

```odin
Clock_Extra :: enum {
	Bullet_Time,
	Cutscene,
}

time.set_time_scale(0.2, .Bullet_Time)
time.set_paused(true, .Cutscene)
time.set_base(.Cutscene, .Unscaled)
```

- An added clock follows one built-in clock, its base. The base is `Update` unless `time.set_base` names another.
- It has a scale and a pause of its own on top. Its step is the base's step times its scale.
- One on `Update` slows down with the game. One on `Unscaled` does not.
- One on `Fixed` advances on the fixed tick. `time.is_fixed` tells which stage a clock advances in.
- A clock gives a group of timed things one switch: everything on `Bullet_Time` slows down together.
- A `time.Clock` field saves as the clock's name, so scenes keep their meaning when a package that adds clocks comes or goes. A name no installed package declares reads as `Update`.
- `plugins/plugin_example/plugin_example.odin` declares `Example_Slow` as the reference.

## Who advances it

The package only keeps the numbers. Whoever runs the frame advances it, before the procs of each stage run:

- The engine's `frame_tick` calls `time.scale_frame` for the frame's scaled step, `time.advance_fixed` for each fixed tick and `time.advance_frame` once per frame ([Fixed tick](/plugins/engine/docs/FixedTick.md)).
- `time.reset` starts every clock from 0 at scale 1. The engine calls it when Play ends.
- An app without the engine drives it the same way from its own loop.
