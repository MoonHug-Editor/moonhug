package engine

// Fixed-rate simulation tick (docs/FixedTick.md). ONE project tick rate — no
// independent per-system rates; coarse systems schedule with the divisor on
// their @(fixed_update) attribute instead. The app loop drives the generated
// __fixed_update through fixed_frame_ticks (classic accumulator):
//
//   steps := engine.fixed_frame_ticks(gfx.delta_time())
//   for _ in 0 ..< steps {
//       input.fixed_latch()
//       __fixed_update(engine.fixed_dt())
//       engine.fixed_tick_advance()
//   }
//
// @(update) stays per-frame for view-side work (tweens, camera, UI).

// 60 rather than Unity's 50: with view interpolation deferred, 60 aligns
// 1:1 with 60 Hz displays (1:2 with 120 Hz ProMotion) so fixed-stepped
// motion shows no cadence judder. Revisit when interpolation lands.
FIXED_RATE_DEFAULT :: f32(60)

// Spiral-of-death guard: after a stall (window drag, debugger pause) at most
// this many catch-up ticks run and the REST OF THE BACKLOG IS DROPPED — the
// sim jumps rather than freezing the frame loop trying to catch up.
FIXED_MAX_CATCHUP_TICKS :: 5

_fixed: struct {
	rate:        f32,
	accumulator: f64,
	tick:        u64,
}

fixed_rate :: proc() -> f32 {
	return _fixed.rate > 0 ? _fixed.rate : FIXED_RATE_DEFAULT
}

// Future ProjectSettings hook; takes effect at the next frame's accumulation.
fixed_set_rate :: proc(hz: f32) {
	_fixed.rate = hz
}

fixed_dt :: proc() -> f32 {
	return 1.0 / fixed_rate()
}

// Index of the tick currently running (advance AFTER each tick). Divisor
// scheduling in the generated dispatcher reads this: `tick % N == 0`.
fixed_tick_index :: proc() -> u64 {
	return _fixed.tick
}

fixed_tick_advance :: proc() {
	_fixed.tick += 1
}

// Consume a frame's dt and return how many fixed ticks to run now (0..max).
// The fractional remainder stays in the accumulator for the next frame.
fixed_frame_ticks :: proc(frame_dt: f32) -> int {
	_fixed.accumulator += f64(frame_dt)
	dt := f64(fixed_dt())
	n := 0
	for _fixed.accumulator >= dt {
		_fixed.accumulator -= dt
		n += 1
	}
	if n > FIXED_MAX_CATCHUP_TICKS {
		n = FIXED_MAX_CATCHUP_TICKS
		_fixed.accumulator = 0
	}
	return n
}

// Tests / playmode restarts.
fixed_reset :: proc() {
	_fixed = {}
}
