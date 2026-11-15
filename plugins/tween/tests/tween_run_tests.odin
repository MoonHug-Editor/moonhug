package tween_tests

// Runs and their handle: stop, complete, pause, time scale, on_complete, bind,
// timelines, easing and cycles.

import "core:testing"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"

@(private = "file")
_DT :: f32(1.0 / 64.0) // exact in binary, so sums of steps are exact

@(private = "file")
_tick :: proc(steps: int) {
	for _ in 0 ..< steps do tween.tick_all(_DT)
}

@(private = "file")
_move :: proc(to: [3]f32, duration: f32, ease := tween.Ease.Linear, cycles: i32 = 0, mode := tween.Cycle_Mode.Restart) -> tween.Authored {
	node := tween.TweenMoveToLocal{position = to, duration = duration}
	node.ease = ease
	node.cycles = cycles
	node.cycle_mode = mode
	return tween.authored(node)
}

@(private = "file")
_pos :: proc(h: engine.Transform_Handle) -> [3]f32 {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h)).position
}

@(private = "file")
_near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

@(private = "file")
_completed: int

@(private = "file")
_count_complete :: proc(user: rawptr) {
	_completed += 1
}

@(test)
test_run_handle_lives_until_the_run_ends :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Subject")
	a := _move({4, 0, 0}, 0.5)
	defer tween.authored_destroy(&a)

	testing.expect(t, !tween.is_alive({}), "the zero handle is no run")
	h := tween.run(&a, tween.TweenContext{subject = owner})
	testing.expect(t, tween.is_alive(h))
	_completed = 0
	tween.on_complete(h, _count_complete)

	_tick(16) // 0.25 s: half way
	testing.expect(t, _near(_pos(owner).x, 2))
	p, ok := tween.progress(h)
	testing.expect(t, ok && _near(p, 0.5), "half way through a 0.5 s run")
	testing.expect_value(t, _completed, 0)

	_tick(17)
	testing.expect(t, !tween.is_alive(h), "a finished run is gone")
	testing.expect_value(t, _pos(owner), [3]f32{4, 0, 0})
	testing.expect_value(t, _completed, 1)

	// The slot is reused, the old handle stays dead.
	h2 := tween.run(&a, tween.TweenContext{subject = owner})
	testing.expect(t, tween.is_alive(h2) && !tween.is_alive(h))
	testing.expect_value(t, h2.index, h.index)
}

@(test)
test_stop_keeps_values_and_complete_jumps_to_the_end :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Subject")
	a := tween.authored(tween.Sequence{}, {
		_move({4, 0, 0}, 0.5),
		_move({4, 8, 0}, 0.5),
	})
	defer tween.authored_destroy(&a)

	_completed = 0
	h := tween.run(&a, tween.TweenContext{subject = owner})
	tween.on_complete(h, _count_complete)
	_tick(16)
	tween.stop(h)
	testing.expect(t, !tween.is_alive(h))
	testing.expect(t, _near(_pos(owner).x, 2), "stop leaves the value where it is")
	testing.expect_value(t, _completed, 0)
	_tick(64)
	testing.expect(t, _near(_pos(owner).x, 2), "a stopped run no longer moves its subject")

	h = tween.run(&a, tween.TweenContext{subject = owner})
	tween.on_complete(h, _count_complete)
	_tick(4)
	tween.complete(h)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _pos(owner), [3]f32{4, 8, 0})
	testing.expect_value(t, _completed, 1)
}

@(test)
test_pause_and_time_scale :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Subject")
	a := _move({8, 0, 0}, 1)
	defer tween.authored_destroy(&a)

	h := tween.run(&a, tween.TweenContext{subject = owner})
	_tick(16) // 0.25 s
	tween.set_paused(h, true)
	testing.expect(t, tween.is_paused(h))
	_tick(64)
	testing.expect(t, _near(_pos(owner).x, 2), "a paused run holds its place")

	tween.set_paused(h, false)
	tween.set_time_scale(h, 2)
	_tick(16) // 0.25 s at double speed
	testing.expect(t, _near(_pos(owner).x, 6))
	testing.expect(t, _near(tween.elapsed(h), 0.75))
}

@(test)
test_ease_and_cycles :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Subject")
	ctx := tween.TweenContext{subject = owner}

	// Quad_In is t*t: a quarter of the way at half time.
	quad := _move({8, 0, 0}, 1, .Quad_In)
	defer tween.authored_destroy(&quad)
	h := tween.run(&quad, ctx)
	_tick(32)
	testing.expect(t, _near(_pos(owner).x, 2))
	tween.complete(h)
	testing.expect_value(t, _pos(owner), [3]f32{8, 0, 0})

	// Yoyo, two cycles: out and back to the start.
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(owner)).position = {}
	yoyo := _move({8, 0, 0}, 0.5, cycles = 2, mode = .Yoyo)
	defer tween.authored_destroy(&yoyo)
	h = tween.run(&yoyo, ctx)
	_tick(48) // 0.75 s: half way back
	testing.expect(t, _near(_pos(owner).x, 4))
	_tick(17)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _pos(owner), [3]f32{0, 0, 0})

	// Incremental, three cycles: each one adds the same step.
	inc := _move({2, 0, 0}, 0.25, cycles = 3, mode = .Incremental)
	defer tween.authored_destroy(&inc)
	h = tween.run(&inc, ctx)
	_tick(24) // 0.375 s: half of the second cycle
	testing.expect(t, _near(_pos(owner).x, 3))
	_tick(26)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _pos(owner), [3]f32{6, 0, 0})

	// Endless: runs until it is told to end, and complete ends the cycle it is in.
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(owner)).position = {}
	endless := _move({8, 0, 0}, 0.5, cycles = -1)
	defer tween.authored_destroy(&endless)
	h = tween.run(&endless, ctx)
	_, known := tween.progress(h)
	testing.expect(t, !known, "an endless run has no progress")
	_tick(200)
	testing.expect(t, tween.is_alive(h))
	tween.complete(h)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _pos(owner), [3]f32{8, 0, 0})
}

@(test)
test_runs_follow_their_timeline :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()
	engine.time_reset()
	defer engine.time_reset()

	scaled := engine.transform_new("Scaled")
	unscaled := engine.transform_new("Unscaled")
	fixed := engine.transform_new("Fixed")
	a := _move({8, 0, 0}, 1)
	defer tween.authored_destroy(&a)

	tween.run(&a, tween.TweenContext{subject = scaled})
	tween.run(&a, tween.TweenContext{subject = unscaled}, .Unscaled)
	tween.run(&a, tween.TweenContext{subject = fixed}, .Fixed)

	engine.set_time_scale(0.5)
	for _ in 0 ..< 32 { // 0.5 s of real frames, no fixed tick
		engine.time_advance_frame(engine.time_scale_frame(_DT), _DT)
		tween.tween_update(_DT)
	}
	testing.expect(t, _near(_pos(scaled).x, 2), "Update runs at half speed")
	testing.expect(t, _near(_pos(unscaled).x, 4), "Unscaled ignores the scale")
	testing.expect(t, _near(_pos(fixed).x, 0), "a Fixed run waits for fixed ticks")

	for _ in 0 ..< 16 {
		engine.time_advance_fixed(_DT)
		tween.tween_fixed_update(_DT)
	}
	testing.expect(t, _near(_pos(fixed).x, 2))
	testing.expect(t, _near(_pos(scaled).x, 2), "a frame run does not move on fixed ticks")

	engine.set_time_paused(true)
	for _ in 0 ..< 16 {
		engine.time_advance_frame(engine.time_scale_frame(_DT), _DT)
		tween.tween_update(_DT)
	}
	testing.expect(t, _near(_pos(scaled).x, 2), "held time holds its runs")
	testing.expect(t, _near(_pos(unscaled).x, 6))
}

@(test)
test_bind_and_stop_on :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	subject := engine.transform_new("Subject")
	owner := engine.transform_new("Owner")
	a := _move({8, 0, 0}, 1)
	defer tween.authored_destroy(&a)

	// Not bound: the owner's state changes nothing.
	free_run := tween.run(&a, tween.TweenContext{subject = subject})
	bound := tween.run(&a, tween.TweenContext{subject = subject})
	tween.bind(bound, owner)

	engine.transform_set_active(owner, false)
	_tick(16)
	testing.expect(t, _near(tween.elapsed(free_run), 0.25))
	testing.expect(t, _near(tween.elapsed(bound), 0), "a bound run waits while its object is inactive")

	engine.transform_set_active(owner, true)
	_tick(16)
	testing.expect(t, _near(tween.elapsed(bound), 0.25))

	engine.transform_destroy(owner)
	_tick(1)
	testing.expect(t, !tween.is_alive(bound), "a bound run stops with its object")
	testing.expect(t, tween.is_alive(free_run))

	tween.stop_on(subject)
	testing.expect(t, !tween.is_alive(free_run))
	testing.expect_value(t, tween.run_count(), 0)
}

@(private = "file")
_chain_next: ^tween.Authored
@(private = "file")
_chain_subject: engine.Transform_Handle
@(private = "file")
_chain_handle: tween.Handle

@(test)
test_on_complete_may_start_the_next_run :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Subject")
	first := _move({4, 0, 0}, 0.25)
	defer tween.authored_destroy(&first)
	second := _move({4, 4, 0}, 0.25)
	defer tween.authored_destroy(&second)

	_chain_next, _chain_subject, _chain_handle = &second, owner, {}
	h := tween.run(&first, tween.TweenContext{subject = owner})
	tween.on_complete(h, proc(user: rawptr) {
		_chain_handle = tween.run(_chain_next, tween.TweenContext{subject = _chain_subject})
	})
	_tick(17)
	testing.expect(t, !tween.is_alive(h) && tween.is_alive(_chain_handle))
	_tick(17)
	testing.expect_value(t, _pos(owner), [3]f32{4, 4, 0})
	testing.expect_value(t, tween.run_count(), 0)
}
