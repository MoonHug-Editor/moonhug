package tests

// engine.frame_tick: the frame's simulation stages run in order, fixed ticks
// from the accumulator and a step runs exactly one of each.

import "core:testing"
import "moonhug:packages/engine"

@(private = "file")
_stages: [16]string
@(private = "file")
_stage_n: int

@(private = "file")
_record :: proc(name: string) {
	if _stage_n < len(_stages) {
		_stages[_stage_n] = name
		_stage_n += 1
	}
}

@(private = "file")
_hooks := engine.Tick_Hooks{
	fixed_update = proc(dt: f32) { _record("fixed") },
	update       = proc(dt: f32) { _record("update") },
	late_update  = proc(dt: f32) { _record("late") },
}

@(test)
test_frame_tick_runs_stages_in_order :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.fixed_reset()
	defer engine.fixed_reset()

	// Two fixed ticks' worth of frame time: both fixed ticks, then update, then late.
	_stage_n = 0
	engine.frame_tick(_hooks, engine.fixed_dt() * 2)
	testing.expect_value(t, _stage_n, 4)
	testing.expect_value(t, _stages[0], "fixed")
	testing.expect_value(t, _stages[1], "fixed")
	testing.expect_value(t, _stages[2], "update")
	testing.expect_value(t, _stages[3], "late")

	// A frame shorter than a tick runs no fixed tick, the frame stages still run.
	_stage_n = 0
	engine.frame_tick(_hooks, engine.fixed_dt() * 0.25)
	testing.expect_value(t, _stage_n, 2)
	testing.expect_value(t, _stages[0], "update")
	testing.expect_value(t, _stages[1], "late")

	// A step is one fixed tick and one frame, whatever the accumulator holds.
	_stage_n = 0
	engine.frame_tick(_hooks, 0, step = true)
	testing.expect_value(t, _stage_n, 3)
	testing.expect_value(t, _stages[0], "fixed")

	// A stage nobody subscribes to is skipped.
	_stage_n = 0
	engine.frame_tick({update = _hooks.update}, engine.fixed_dt() * 2)
	testing.expect_value(t, _stage_n, 1)
	testing.expect_value(t, _stages[0], "update")
}
