package engine_tests

// The game's time (moonhug/libs/time) as the engine drives it: frame_tick
// advances the clocks, the time scale slows frames and fixed ticks, Unscaled
// follows neither.

import "core:testing"
import "moonhug:libs/time"
import "moonhug:packages/engine"

@(private = "file")
_update_arg, _update_delta: f32
@(private = "file")
_fixed_ticks: int

@(private = "file")
_time_hooks := engine.Tick_Hooks{
	fixed_update = proc(dt: f32) { _fixed_ticks += 1 },
	update       = proc(dt: f32) { _update_arg, _update_delta = dt, time.delta_time() },
}

@(test)
test_time_advances_with_frame_tick :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.fixed_reset()
	defer engine.fixed_reset()

	fdt := engine.fixed_dt()
	_fixed_ticks = 0
	engine.frame_tick(_time_hooks, fdt * 2)

	// delta_time() inside an update proc is that proc's dt, this frame's.
	testing.expect_value(t, _update_arg, fdt * 2)
	testing.expect_value(t, _update_delta, fdt * 2)
	testing.expect_value(t, _fixed_ticks, 2)
	testing.expect(t, abs(time.now() - f64(fdt * 2)) < 1e-6, "Update advances by the frame")
	testing.expect(t, abs(time.now(.Fixed) - f64(fdt * 2)) < 1e-6, "Fixed advances once per fixed tick")
	testing.expect(t, abs(time.now(.Unscaled) - f64(fdt * 2)) < 1e-6)
	testing.expect_value(t, time.frame_count(), u64(1))
	testing.expect(t, time.is_fixed(.Fixed) && !time.is_fixed(.Update) && !time.is_fixed(.Unscaled))
}

@(test)
test_time_scale_slows_frames_and_fixed_ticks :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.fixed_reset()
	defer engine.fixed_reset()

	fdt := engine.fixed_dt()

	// Half speed: four ticks' worth of real time runs two ticks.
	time.set_time_scale(0.5)
	_fixed_ticks = 0
	engine.frame_tick(_time_hooks, fdt * 4)
	testing.expect_value(t, _fixed_ticks, 2)
	testing.expect_value(t, _update_arg, fdt * 2)
	testing.expect_value(t, time.delta_time(), fdt * 2)
	testing.expect_value(t, time.delta_time(.Unscaled), fdt * 4)

	// Scale 0 holds the game: no fixed tick, a frame of 0, real time goes on.
	time.set_time_scale(0)
	_fixed_ticks = 0
	engine.frame_tick(_time_hooks, fdt * 4)
	testing.expect_value(t, _fixed_ticks, 0)
	testing.expect_value(t, _update_arg, f32(0))
	testing.expect(t, abs(time.now(.Unscaled) - f64(fdt * 8)) < 1e-6)
	testing.expect(t, abs(time.now() - f64(fdt * 2)) < 1e-6, "held time keeps its place")

	// Paused holds the game too and keeps the scale.
	time.set_time_scale(1)
	time.set_paused(true)
	engine.frame_tick(_time_hooks, fdt * 4)
	testing.expect_value(t, _update_arg, f32(0))
	testing.expect_value(t, time.time_scale(), f32(1))

	// A step ignores the scale and the pause: one tick, one frame.
	_fixed_ticks = 0
	engine.frame_tick(_time_hooks, 0, step = true)
	testing.expect_value(t, _fixed_ticks, 1)
	testing.expect_value(t, _update_arg, fdt)

	// A reset is a new run: time 0, scale 1, running.
	time.reset()
	testing.expect_value(t, time.now(), f64(0))
	testing.expect_value(t, time.time_scale(), f32(1))
	testing.expect(t, !time.paused())
	testing.expect_value(t, time.frame_count(), u64(0))
}
