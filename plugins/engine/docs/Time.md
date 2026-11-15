---
title: "Time"
description: "The game's time: delta time, the time scale, unscaled and fixed time, and the timelines timed systems run on, built-in and added by packages"
weight: 75
tags: ["engine", "time"]
path: engine/concepts/frame
---

The game's time, its scale, and the timelines that timed systems such as tweens run on. The code is `plugins/engine/time.odin`.

## Reading time

```odin
dt := engine.delta_time()             // this frame's step in seconds, scaled
now := engine.time_now()              // seconds since Play started, scaled
real := engine.unscaled_delta_time()  // this frame's real step
engine.unscaled_time()                // real seconds since Play started
engine.fixed_time()                   // seconds the fixed tick has simulated
engine.fixed_dt()                     // the step of one fixed tick
engine.frame_count()                  // frames since Play started
```

- Inside an `@(update)` proc, `delta_time()` is that proc's `dt`.
- `time` itself is the name of Odin's time package, so the seconds are `time_now`.
- Everything starts from 0 when Play starts.

## The time scale

```odin
engine.set_time_scale(0.25)   // slow motion
engine.set_time_scale(0)      // hold the game
engine.set_time_scale(1)      // real speed
```

- The time scale is one number for the whole game.
- It scales the delta time that `@(update)` and `@(late_update)` procs get.
- It scales how fast fixed ticks come. At 0.5 a fixed tick runs half as often, still with the full fixed step, so the simulation stays stable.
- At 0 no fixed tick runs and the frame's delta time is 0.
- `unscaled_delta_time` and `unscaled_time` ignore it. A menu that has to move while the game is held uses them.
- `set_time_paused(true)` holds the game the same way and keeps the scale for later.
- The editor's Step button runs one fixed tick and one frame whatever the scale is.

## Timelines

`engine.Time` names a timeline. A timed system takes one where its time is a choice, and uses `Update` when none is given.

| Timeline | Advances | By |
|---|---|---|
| `Update` | every frame | the scaled delta time |
| `Fixed` | every fixed tick | the fixed step |
| `Unscaled` | every frame | the real delta time |

`delta_time`, `time_now`, `time_scale` and `time_paused` take a timeline: `engine.delta_time(.Unscaled)`.

## Adding a timeline

A package adds timelines with a `Time_Extra` enum of its own. Prebuild lists its values after the built-in ones in the generated `engine.Time` enum, so every package names them the same way.

```odin
Time_Extra :: enum {
	Bullet_Time,
	Cutscene,
}

engine.set_time_scale(0.2, .Bullet_Time)
engine.set_time_paused(true, .Cutscene)
engine.set_time_base(.Cutscene, .Unscaled)
```

- An added timeline follows one built-in timeline, its base. The base is `Update` unless `set_time_base` names another.
- It has a scale and a pause of its own on top. Its step is the base's step times its scale.
- One on `Update` slows down with the game. One on `Unscaled` does not.
- One on `Fixed` advances on the fixed tick. `time_is_fixed` tells which stage a timeline advances in.
- A timeline gives a group of timed things one switch: everything on `Bullet_Time` slows down together.
- `plugins/plugin_example/plugin_example.odin` declares `Example_Slow` as the reference.

## What runs on timelines

- Tweens: `tween.run` takes the timeline a run ticks on ([tween](/plugins/tween/docs/_index.md)).
