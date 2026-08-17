package tween_tests

// The handle-based runtime end to end: authored blobs instantiate into
// pooled nodes, composites gate their children, finished runs free their
// trees (the test allocator would flag a leaked node's heap).

import "moonhug:engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_sequence_runs_children_in_order :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	owner := engine.transform_new("Subject")

	a := tween.authored(tween.Sequence{}, {
		tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}, duration = 0.1}),
		tween.authored(tween.TweenMoveToLocal{position = {1, 2, 0}, duration = 0.1}),
	})
	defer tween.authored_destroy(&a)

	ok := tween.tween_run(&a, tween.TweenContext{subject = owner})
	testing.expect(t, ok, "sequence should start")

	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))

	// After a few ticks the first child is still running: y untouched.
	for _ in 0 ..< 3 do tween.tween_tick_running(1.0 / 60.0, {})
	testing.expect(t, tr.position.y == 0, "second child must not run before the first is done")

	for _ in 0 ..< 60 do tween.tween_tick_running(1.0 / 60.0, {})
	testing.expect_value(t, tr.position, [3]f32{1, 2, 0})
}

@(test)
test_parallel_runs_all_children :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	owner := engine.transform_new("Subject")

	a := tween.authored(tween.Parallel{}, {
		tween.authored(tween.TweenMoveToLocal{position = {3, 0, 0}, duration = 0.1}),
		tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}, duration = 0.1}),
	})
	defer tween.authored_destroy(&a)

	ok := tween.tween_run(&a, tween.TweenContext{subject = owner})
	testing.expect(t, ok, "parallel should start")

	for _ in 0 ..< 60 do tween.tween_tick_running(1.0 / 60.0, {})

	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
}

@(test)
test_skip_prevents_run :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	owner := engine.transform_new("Subject")

	move := tween.TweenMoveToLocal{position = {9, 0, 0}, duration = 0.1}
	move.skip = true
	a := tween.authored(move)
	defer tween.authored_destroy(&a)

	ok := tween.tween_run(&a, tween.TweenContext{subject = owner})
	testing.expect(t, !ok, "a skipped root must not start")
}
