---
title: "Runs"
description: "The handle of a running tween tree: stop, complete, pause, time scale, progress, the completion callback, the clock a run ticks on and binding a run to an object"
weight: 20
tags: ["tween", "concepts"]
---

A run is one live tween tree. `tween.run` starts it and returns its handle. The code is `runs.odin`.

## The handle

```odin
h := tween.run("Open", tween.TweenContext{subject = door})

tween.is_alive(h)           // true until the run ends
tween.stop(h)               // end it where it is
tween.complete(h)           // end it at its end
tween.set_paused(h, true)   // hold it
tween.set_time_scale(h, 2)  // twice as fast
```

- The zero handle is no run. `tween.run` returns it when nothing started: an unknown name, a node type that is not registered, a skipped root, a node `subject` that names no object.
- The `subject` in the `TweenContext` is the default object. A node whose own `subject` is set in the inspector animates that one ([Tween nodes](../scripts/TweenNodes.md)).
- Every proc accepts the zero handle and the handle of a run that ended, and does nothing then.
- A handle never reaches a later run, so keeping an old one is safe.

## How a run ends

| Way | Values | `tween.on_complete` |
|---|---|---|
| It finishes: its tree is done | at their end | called |
| `tween.complete` | jump to their end | called |
| `tween.stop` | stay where they are | not called |

- `tween.complete` ends an endless node (`cycles = -1`) at the end of the cycle it is in.
- `tween.stop_on(object)` and `tween.complete_on(object)` end every run whose subject or bound object is that object. `tween.stop_all` stops every run.
- Play ending stops every run.

## Completion callback

```odin
tween.on_complete(h, proc(user: rawptr) {
	door := cast(^Door)user
	door.is_open = true
}, door)
```

- The proc is called once, after the run is gone, so it may start the next run.
- Odin has no closures: what the proc needs travels in `user`.

## Pause, speed and progress

- A paused run keeps its place. `tween.is_paused` reads the flag.
- The time scale is the run's own speed on top of its clock: 1 by default, 0 holds it.
- `tween.elapsed` is the seconds the run has advanced.
- `tween.progress` is 0 at the start and 1 at the end. Its second result is false when the run's length cannot be told: a tree with an endless node, or with a node that ticks itself and has no children.

## Clocks

A run ticks on one of the game's clocks ([Time](/docs/core/Time.md)), `Update` unless `tween.run` names another.

```odin
tween.run("Bounce", ctx)                     // Update: follows the game's time scale
tween.run("Recoil", ctx, .Fixed)             // steps with the simulation
tween.run("MenuSlide", ctx, .Unscaled)       // keeps moving while the game is held
tween.run("Dodge", ctx, .Bullet_Time)        // a clock a package adds
```

- A clock's scale and pause apply to every run on it, which gives a group of runs one switch.
- Runs on `Fixed`, and on clocks based on it, advance on the fixed tick. The others advance every frame.
- `tween.tick_all(dt)` ticks every run by `dt` whatever its clock, for tests and for stepping by hand.

- An authored tree names its own clock on its root node (`own_clock` and `clock`). It then runs on that clock whatever the code passes, the same way a node's own `subject` wins over the code's.

## Rewind, keeping and stepping by hand

What a preview needs, and a tool that scrubs a tween:

```odin
tween.set_paused(h, true)   // the game's ticks leave it alone
tween.set_keep_when_done(h, true) // it stays alive when its tree is done
tween.tick(h, dt)           // one run, by hand, paused or not
tween.is_done(h)            // its tree is done
tween.rewind(h)             // end it and put back every value it changed
tween.unapply(h)            // put back every value, keep the run
tween.replay(h)             // pose it again
```

- `tween.unapply(h)` puts back what the run changed and keeps the run where it is. `tween.replay(h)` poses it again, capturing each start from the world as it is then. A preview brackets the render with the two, so nothing outside the render sees the pose.
- `tween.rewind` makes every value node that began write its start value again, the newest first, so each finds what it captured. The run ends and `on_complete` is not called.
- A kept run that is done keeps every value at its end until it is stopped or rewound.
- `tween.run_infos()` lists the live runs for tools: handle, root node type, object, clock, time and state. The [Tweens window](../windows/TweensWindow.md) shows it.

## Binding a run to an object

Nothing ties a run to an object by default: a run started from a component keeps going when that component is disabled or destroyed. `tween.bind` hands a run over to an object.

```odin
h := tween.run("Pulse", tween.TweenContext{subject = icon})
tween.bind(h, panel)
```

- A bound run stops when its object is destroyed.
- A bound run does not advance while its object is inactive, and goes on when it is active again.
- The bound object and the subject are separate: a panel can own a run that animates one of its icons.
- A value node ends by itself when its subject is destroyed, bound or not.
