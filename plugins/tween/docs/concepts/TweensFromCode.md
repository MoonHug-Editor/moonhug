---
title: "Tweens from code"
description: "Starting a tween with one call, animating any value through a proc, delays, and building a sequence step by step with chain, group and insert"
weight: 15
tags: ["tween", "concepts"]
---

A tween does not have to be authored. One call starts one, and a sequence is built step by step. The calls make the same pooled nodes an authored tree runs as, and return the same handle ([Runs](Runs.md)). The code is `code.odin`.

## One-line tweens

```odin
import tween "moonhug:packages/tween"

tween.position(door, {0, 2, 0}, 0.3)                 // local position
tween.scale(icon, {1.2, 1.2, 1.2}, 0.15, .Back_Out)  // with an ease
tween.euler_angles(lid, {0, 0, 90}, 0.5)             // degrees
tween.rotation(lid, quat, 0.5)                       // a quaternion
```

- The arguments are the object, the end value, the duration in seconds and the ease. The start is where the object is when the tween begins.
- Each call returns a handle: `h := tween.position(...)`, then `tween.stop(h)`, `tween.complete(h)`, `tween.on_complete(h, ...)`.
- A tween starts at once and ticks from the next frame.

## Options

The last argument sets the rest. Its zero value is: play once, no delay, on `Update`.

```odin
tween.position(coin, {0, 1, 0}, 0.5, .Sine_In_Out, {cycles = -1, cycle_mode = .Yoyo})
tween.scale(popup, {1, 1, 1}, 0.2, opt = {delay = 0.5, time = .Unscaled})
tween.position(ball, target, 1, opt = {curve = &my_curve})
```

| Field | What it does |
|---|---|
| `cycles` | How many times it plays. 0 and 1 play once, -1 repeats until stopped or completed. |
| `cycle_mode` | `Restart`, `Yoyo`, `Incremental` or `Rewind` ([Tween nodes](../scripts/TweenNodes.md)). |
| `delay` | Seconds before it starts. |
| `time` | The timeline it ticks on ([Time](/plugins/engine/docs/Time.md)). |
| `curve` | The ease as a curve from 0 to 1 on both axes. The curve is copied. |

## Any value

`tween.custom` animates a value that is not a transform. It calls a proc every tick with the value between `from` and `to`.

```odin
set_alpha :: proc(value: f32, user: rawptr) {
	(cast(^Panel)user).alpha = value
}

tween.custom(0, 1, 0.5, set_alpha, panel)
tween.custom(panel.color, RED, 0.2, set_color, panel)   // set_color takes [4]f32
```

- The value is a number, or a vector of 2, 3 or 4 numbers. A color is 4. The proc's argument type picks the form.
- Odin has no closures: what the proc needs travels in `user`.
- `user` has to stay valid for as long as the tween runs. Stop the tween when what it points at goes away.

## Delay

```odin
tween.delay(2, explode, bomb)   // calls explode(bomb) after 2 seconds
h := tween.delay(1)             // a run that only takes time
```

## Sequences

`tween.sequence()` starts an empty sequence. Steps go in with `chain`, `group` and `insert`.

```odin
s := tween.sequence()
tween.chain(s, tween.position(door, {0, 2, 0}, 0.3))
tween.group(s, tween.scale(door, {1.1, 1.1, 1.1}, 0.3))   // together with the move
tween.chain_delay(s, 1)
tween.chain_callback(s, door_opened, door)
tween.chain(s, tween.position(door, {0, 0, 0}, 0.3))
tween.insert(s, 0.5, tween.custom(0, 1, 0.2, set_glow, door))   // at 0.5 s
```

| Call | What it does |
|---|---|
| `chain(s, step)` | Puts the step after everything chained so far. |
| `group(s, step)` | Puts the step next to the last chained one. Both start together, and the sequence goes on when both are done. |
| `insert(s, at, step)` | Puts the step at `at` seconds from the start, whatever is chained. |
| `chain_delay(s, seconds)` | Chains a pause. |
| `chain_callback(s, call, user)` | Chains a call. |
| `insert_callback(s, at, call, user)` | Makes a call at `at` seconds from the start. |
| `chain_wait_until(s, until, user)` | Holds the sequence until `until(user)` returns true. |

- A step is any tween: a one-line tween, a `custom`, a `delay`, an authored tree started with `tween.run`, or another sequence.
- A step handed to a sequence stops being a run of its own. Its handle is dead from then on, and the sequence's handle controls it.
- A step joins a sequence before it has ticked, so a sequence is built in the frame it starts in.
- Each step keeps its own object. The sequence's timeline is the one every step ticks on.
- `tween.complete(s)` runs every step to its end and still makes the calls. It does not wait at a `chain_wait_until`.
- A sequence with a `chain_wait_until` has no progress, since its length cannot be told.

## One at a time

A handle kept in a component is enough to keep a tween from doubling up.

```odin
// Replace what is playing.
tween.stop(d.fade)
d.fade = tween.custom(d.alpha, 0, 0.3, set_alpha, d)

// Leave what is playing alone.
if !tween.is_alive(d.fade) do d.fade = tween.custom(d.alpha, 0, 0.3, set_alpha, d)

// Play after what is playing.
next := tween.position(d.owner, {0, 2, 0}, 0.3)
tween.wait_for(next, d.move)
d.move = next
```

- `tween.stop` and `tween.is_alive` accept the zero handle and a dead one, so no check is needed first.
- `tween.wait_for(h, other)` holds a run until the other one has ended.
- `tween.stop_on(object)` stops every tween that animates an object, whoever started it.
