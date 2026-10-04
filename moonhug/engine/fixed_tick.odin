package engine

// Fixed-rate simulation tick (docs/core/FixedTick.md). ONE project tick rate — no
// independent per-system rates; coarse systems schedule with the divisor on
// their @(fixed_update) attribute instead. The app loop drives the generated
// __fixed_update through fixed_frame_ticks (classic accumulator):
//
//   steps := engine.fixed_frame_ticks(gfx.delta_time())
//   for _ in 0 ..< steps {
//       engine.fixed_tick_begin()
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
	in_tick:     bool, // between fixed_tick_begin and fixed_tick_advance
}

fixed_rate :: proc() -> f32 {
	if _fixed.rate > 0 do return _fixed.rate
	_ensure_time_settings()
	if time_settings.fixed_rate > 0 do return time_settings.fixed_rate
	return FIXED_RATE_DEFAULT
}

// Explicit override; wins over the Time project setting until reset to 0.
// Takes effect at the next frame's accumulation.
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

// A tick starts. Gizmos the previous tick recorded go now: they stayed up to
// here so frames that run no tick still show them.
fixed_tick_begin :: proc() {
	_fixed.in_tick = true
	if uc := ctx_get(); uc != nil do gizmo_buffer_clear_lifetime(&uc.gizmos, .Fixed_Tick)
}

fixed_tick_advance :: proc() {
	_fixed.tick += 1
	_fixed.in_tick = false
}

// True while a fixed tick runs (engine/gizmos records with .Fixed_Tick then).
fixed_in_tick :: proc() -> bool {
	return _fixed.in_tick
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
	// The last tick's gizmos describe a run that ended, and the game clock
	// restarts, so its timed gizmos go too.
	if uc := ctx_get(); uc != nil {
		gizmo_buffer_clear_lifetime(&uc.gizmos, .Fixed_Tick)
		gizmo_buffer_clear_clock(&uc.gizmos, .Game)
	}
}

// Runs a proc every frame, with the frame's delta time in seconds.
//
// `order` sorts procs across all packages. For view-side work: tweens, camera,
// UI. Simulation belongs in @(fixed_update).
//
// The signatures of the procs the two tick attributes run.
@(extension_point={attribute="update", target="proc", fields="order"})
Update_Proc :: proc(dt: f32)

// Runs a proc on the fixed simulation tick, with the fixed step in seconds.
//
// `order` sorts procs across all packages, and `divisor = N` runs it on every
// Nth tick only, for coarse systems. The tick rate is one project setting,
// Project Settings > Time.
@(extension_point={attribute="fixed_update", target="proc", fields="order divisor"})
Fixed_Update_Proc :: proc(fixed_dt: f32)
