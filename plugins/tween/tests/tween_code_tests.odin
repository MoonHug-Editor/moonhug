package tween_tests

// Tweens from code: one-line starts, custom values, delay, and sequences
// built step by step.

import "core:testing"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"

@(private = "file")
_DT :: f32(1.0 / 64.0)

@(private = "file")
_tick :: proc(steps: int) {
	for _ in 0 ..< steps do tween.tick_all(_DT)
}

@(private = "file")
_tr :: proc(h: engine.Transform_Handle) -> ^engine.Transform {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
}

@(private = "file")
_near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

// What the callbacks of these tests write to.
@(private = "file")
_Probe :: struct {
	number: f32,
	color:  [4]f32,
	calls:  int,
	order:  [8]int,
	gate:   bool,
}

@(private = "file")
_set_number :: proc(value: f32, user: rawptr) {
	(cast(^_Probe)user).number = value
}

@(private = "file")
_set_color :: proc(value: [4]f32, user: rawptr) {
	(cast(^_Probe)user).color = value
}

@(private = "file")
_count :: proc(user: rawptr) {
	(cast(^_Probe)user).calls += 1
}

@(test)
test_one_line_tweens :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	b := engine.transform_new("B")

	// Each tween names its own object, so two run side by side.
	ha := tween.position(a, {8, 0, 0}, 1)
	hb := tween.scale(b, {3, 3, 3}, 0.5, .Quad_In)
	testing.expect(t, tween.is_alive(ha) && tween.is_alive(hb))
	_tick(16) // 0.25 s
	testing.expect(t, _near(_tr(a).position.x, 2))
	testing.expect(t, _near(_tr(b).scale.x, 1 + 2 * 0.25), "Quad_In is a quarter of the way at half time")
	_tick(49)
	testing.expect(t, !tween.is_alive(ha) && !tween.is_alive(hb))
	testing.expect_value(t, _tr(a).position, [3]f32{8, 0, 0})
	testing.expect_value(t, _tr(b).scale, [3]f32{3, 3, 3})

	// Options: a delay, then two Yoyo cycles back to the start.
	_tr(a).position = {}
	h := tween.position(a, {4, 0, 0}, 0.25, opt = {delay = 0.25, cycles = 2, cycle_mode = .Yoyo})
	_tick(16)
	testing.expect(t, _near(_tr(a).position.x, 0), "the delay holds the tween")
	_tick(16)
	testing.expect(t, _near(_tr(a).position.x, 4))
	_tick(17)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, _tr(a).position, [3]f32{0, 0, 0})

	// Euler angles are degrees.
	tween.complete(tween.euler_angles(a, {0, 0, 90}, 1))
	want := engine.quat_from_euler_xyz(0, 0, 90)
	got := _tr(a).rotation
	testing.expect(t, _near(got.x, want.x) && _near(got.y, want.y) && _near(got.z, want.z) && _near(got.w, want.w))
}

@(test)
test_custom_value_and_delay :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	probe: _Probe

	// A number and a color: the setter's type picks the form.
	tween.custom(0, 10, 1, _set_number, &probe)
	tween.custom([4]f32{0, 0, 0, 1}, [4]f32{1, 0.5, 0, 1}, 1, _set_color, &probe)
	_tick(32)
	testing.expect(t, _near(probe.number, 5))
	testing.expect(t, _near(probe.color.r, 0.5) && _near(probe.color.g, 0.25) && _near(probe.color.a, 1))
	_tick(33)
	testing.expect_value(t, probe.number, f32(10))
	testing.expect_value(t, probe.color, [4]f32{1, 0.5, 0, 1})

	// delay calls once, after its time.
	h := tween.delay(0.5, _count, &probe)
	_tick(31)
	testing.expect_value(t, probe.calls, 0)
	_tick(2)
	testing.expect_value(t, probe.calls, 1)
	testing.expect(t, !tween.is_alive(h))

	// No code-made node is offered for authoring.
	for tid in tween.registered_node_types() {
		testing.expect(t, tid != typeid_of(tween.TweenCustom) && tid != typeid_of(tween.TweenCallback) && tid != typeid_of(tween.TweenWaitUntil))
	}
	testing.expect_value(t, tween.run_count(), 0)
}

@(test)
test_built_sequence :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	probe: _Probe

	s := tween.sequence()
	step := tween.position(a, {4, 0, 0}, 0.5)
	tween.chain(s, step)
	testing.expect(t, !tween.is_alive(step), "a chained step is no run of its own")
	tween.group(s, tween.scale(b, {2, 2, 2}, 0.25))        // with the move
	tween.chain_delay(s, 0.25)
	tween.chain_callback(s, _count, &probe)
	tween.chain(s, tween.position(a, {4, 4, 0}, 0.5))
	tween.insert(s, 0.25, tween.position(b, {0, 0, 8}, 0.5)) // at 0.25 s, whatever is chained
	testing.expect_value(t, tween.run_count(), 1)

	p, known := tween.progress(s)
	testing.expect(t, known && p == 0)

	_tick(16) // 0.25 s
	testing.expect(t, _near(_tr(a).position.x, 2))
	testing.expect_value(t, _tr(b).scale, [3]f32{2, 2, 2})
	testing.expect(t, _near(_tr(b).position.z, 0), "the inserted step has not started")
	_tick(16) // 0.5 s
	testing.expect(t, _near(_tr(b).position.z, 4))
	testing.expect_value(t, probe.calls, 0)
	_tick(20) // past the delay
	testing.expect_value(t, probe.calls, 1)
	p, _ = tween.progress(s)
	testing.expect(t, p > 0.5 && p < 1)
	_tick(40)
	testing.expect(t, !tween.is_alive(s))
	testing.expect_value(t, _tr(a).position, [3]f32{4, 4, 0})
	testing.expect_value(t, _tr(b).position, [3]f32{0, 0, 8})

	// complete runs every step to its end and still makes the calls.
	_tr(a).position = {}
	probe.calls = 0
	s = tween.sequence()
	tween.chain(s, tween.position(a, {1, 0, 0}, 1))
	tween.chain_callback(s, _count, &probe)
	tween.chain(s, tween.position(a, {1, 1, 0}, 1))
	tween.on_complete(s, _count, &probe)
	_tick(4)
	tween.complete(s)
	testing.expect_value(t, _tr(a).position, [3]f32{1, 1, 0})
	testing.expect_value(t, probe.calls, 2)
}

@(test)
test_sequence_waits_and_authored_steps :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	probe: _Probe

	// An authored tree is a step like any other and keeps its subject.
	authored := tween.authored(tween.TweenMoveToLocal{position = {0, 6, 0}, duration = 0.25})
	defer tween.authored_destroy(&authored)

	s := tween.sequence()
	tween.chain_wait_until(s, proc(user: rawptr) -> bool { return (cast(^_Probe)user).gate }, &probe)
	tween.chain(s, tween.run(&authored, tween.TweenContext{subject = b}))
	_, known := tween.progress(s)
	testing.expect(t, !known, "a sequence with a wait has no progress")

	_tick(64)
	testing.expect(t, tween.is_alive(s))
	testing.expect(t, _near(_tr(b).position.y, 0), "the sequence holds at the wait")
	probe.gate = true
	_tick(18)
	testing.expect(t, !tween.is_alive(s))
	testing.expect_value(t, _tr(b).position, [3]f32{0, 6, 0})

	// wait_for: the new run starts when the one playing has ended.
	first := tween.position(a, {2, 0, 0}, 0.5)
	second := tween.position(a, {2, 2, 0}, 0.5)
	tween.wait_for(second, first)
	_tick(16)
	testing.expect(t, _near(tween.elapsed(second), 0))
	_tick(17)
	testing.expect(t, !tween.is_alive(first) && tween.is_alive(second))
	_tick(33)
	testing.expect_value(t, _tr(a).position, [3]f32{2, 2, 0})
	testing.expect_value(t, tween.run_count(), 0)
}
