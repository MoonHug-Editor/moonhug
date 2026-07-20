# Fixed Tick

Fixed-rate simulation update. ONE project tick rate (default 60 Hz,
`engine/fixed_tick.odin`) — no per-system rates; coarse systems use the
divisor instead. 60 rather than Unity's 50: without view interpolation it
aligns 1:1 with 60 Hz displays, so fixed-stepped motion shows no cadence
judder.

```odin
@(fixed_update={order=10})            // every tick, fixed_dt
physics_step :: proc(fixed_dt: f32) {}

@(fixed_update={order=20, divisor=4}) // every 4th tick, fixed_dt * 4
ai_tick :: proc(dt: f32) {}

@(update={order=1})                   // stays PER-FRAME: view-side work
tween_tick :: proc(dt: f32) {}
```

- Works in `moonhug/app` and in package runtime code (docs/Plugins.md) —
  prebuild bakes both into `__fixed_update` in `update_generated.odin`,
  interleaved with app entries by order.
- The app loop drives it with an accumulator: consume frame dt, run 0..k
  ticks, carry the remainder. After a stall at most
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
