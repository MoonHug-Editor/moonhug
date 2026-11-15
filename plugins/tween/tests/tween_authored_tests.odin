package tween_tests

// What a tree authors beyond moves: shakes, field tweens, events and its own
// clock. And what a preview and a tool need from a run: rewind, keeping a
// finished run, a tick of one run, and the list of runs.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "moonhug:libs/time"
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
	return abs(a - b) < 1e-3
}

@(private = "file")
_events: [dynamic]string

@(test)
test_authored_shake_fields_and_events :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	// Every one of them is offered for authoring.
	offered := tween.registered_node_types()
	for want in ([]typeid{tween.TweenShake, tween.TweenUITint, tween.TweenCameraFov, tween.TweenLightIntensity, tween.TweenLightColor, tween.TweenEvent}) {
		found := false
		for tid in offered do if tid == want do found = true
		testing.expectf(t, found, "%v is a node a tree authors", want)
	}

	obj := engine.transform_new("Object")
	_tr(obj).position = {3, 3, 3}
	_, cam_raw := engine.transform_add_comp(obj, .Camera)
	camera := cast(^engine.Camera)cam_raw
	camera.fov = 60
	_, light_raw := engine.transform_add_comp(obj, .Light)
	light := cast(^engine.Light)light_raw
	light.intensity = 1
	light.color = {1, 1, 1, 1}
	_, cr_raw := engine.transform_add_comp(obj, .CanvasRenderer)
	cr := cast(^engine.CanvasRenderer)cr_raw

	tint := tween.TweenUITint{tint = {0, 0, 0, 0}, alpha_only = true, duration = 0.5}
	light_color := tween.TweenLightColor{color = {1, 0, 0, 1}, duration = 0.5}
	// A sequence goes on into its next step in the tick a step ends, so the
	// step back waits: the values are checked while it does.
	fov_back := tween.TweenCameraFov{fov = 60, duration = 0.25}
	fov_back.delay = 0.25
	a := tween.authored(tween.Sequence{}, {
		tween.authored(tween.Parallel{}, {
			tween.authored(tween.TweenShake{part = .Position, strength = {1, 0, 0}, frequency = 10, duration = 0.5}),
			tween.authored(tween.TweenCameraFov{fov = 40, duration = 0.5}),
			tween.authored(tween.TweenLightIntensity{intensity = 3, duration = 0.5}),
			tween.authored(light_color),
			tween.authored(tint),
		}),
		tween.authored(tween.TweenEvent{name = "half"}),
		tween.authored(fov_back),
		tween.authored(tween.TweenEvent{name = "end"}),
	})
	defer tween.authored_destroy(&a)

	_events = make([dynamic]string, context.temp_allocator)
	h := tween.run(&a, tween.TweenContext{subject = obj})
	tween.on_event(h, proc(name: string, user: rawptr) {
		append(&_events, strings.clone(name, context.temp_allocator))
	})

	_tick(16)
	testing.expect(t, _tr(obj).position.x != 3, "the authored shake moves the object")
	testing.expect_value(t, len(_events), 0)
	_tick(18)
	testing.expect_value(t, _tr(obj).position, [3]f32{3, 3, 3})
	testing.expect_value(t, camera.fov, f32(40))
	testing.expect_value(t, light.intensity, f32(3))
	testing.expect_value(t, light.color, [4]f32{1, 0, 0, 1})
	testing.expect(t, cr.tinted && cr.tint == [4]f32{1, 1, 1, 0}, "alpha_only fades the tint and leaves its color")
	testing.expect(t, len(_events) == 1 && _events[0] == "half", "the tree called into code by name")
	_tick(33)
	testing.expect(t, !tween.is_alive(h))
	testing.expect_value(t, camera.fov, f32(60))
	testing.expect(t, len(_events) == 2 && _events[1] == "end")
}

@(test)
test_tree_own_clock_saved_by_name :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	obj := engine.transform_new("Object")
	move := tween.TweenMoveToLocal{position = {8, 0, 0}, duration = 1}
	move.own_clock = true
	move.clock = .Unscaled
	a := tween.authored(move)
	defer tween.authored_destroy(&a)

	// The clock is a name in the saved value, not a number.
	bytes, _ := json.marshal(a.value, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, strings.contains(string(bytes), "\"Unscaled\""), "the clock saves as its name")

	// The code asks for Fixed. The root's own clock wins.
	h := tween.run(&a, tween.TweenContext{subject = obj}, .Fixed)
	testing.expect_value(t, tween.clock_of(h), time.Clock.Unscaled)

	// Without own_clock the code's clock is used.
	plain := tween.authored(tween.TweenMoveToLocal{position = {8, 0, 0}, duration = 1})
	defer tween.authored_destroy(&plain)
	testing.expect_value(t, tween.clock_of(tween.run(&plain, tween.TweenContext{subject = obj}, .Fixed)), time.Clock.Fixed)
}

@(test)
test_rewind_hold_and_run_list :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_tr(a).position = {1, 1, 1}
	_tr(b).scale = {2, 2, 2}

	// The same value twice in a row, and another object: rewind has to undo
	// the newest first to land on the very first start.
	s := tween.sequence()
	tween.chain(s, tween.position(a, {5, 1, 1}, 0.25))
	tween.chain(s, tween.position(a, {5, 9, 1}, 0.25))
	tween.group(s, tween.scale(b, {4, 4, 4}, 0.25))
	// A shake starts at no offset, so putting it back is exact too.
	tween.group(s, tween.shake_rotation(b, {10, 20, 30}, 0.25))
	b_rotation := _tr(b).rotation

	// The way a preview drives a run: paused for the game, kept at its end,
	// ticked by hand.
	tween.set_paused(s, true)
	tween.set_keep_when_done(s, true)
	_tick(64)
	testing.expect_value(t, _tr(a).position, [3]f32{1, 1, 1})
	for _ in 0 ..< 24 do tween.tick(s, _DT) // into the second step
	testing.expect(t, _tr(a).position.x == 5 && _tr(a).position.y > 1)
	testing.expect(t, _tr(b).scale.x > 2)

	infos := tween.run_infos()
	testing.expect_value(t, len(infos), 1)
	testing.expect(t, infos[0].handle == s && infos[0].paused && !infos[0].done && infos[0].root == typeid_of(tween.Parallel))
	testing.expect(t, infos[0].length_known && _near(infos[0].length, 0.5) && _near(infos[0].elapsed, 0.375))

	for _ in 0 ..< 12 do tween.tick(s, _DT)
	testing.expect(t, tween.is_alive(s) && tween.is_done(s), "a kept run stays when its tree is done")
	testing.expect_value(t, _tr(a).position, [3]f32{5, 9, 1})
	testing.expect(t, tween.run_infos()[0].done)

	tween.rewind(s)
	testing.expect(t, !tween.is_alive(s))
	testing.expect_value(t, _tr(a).position, [3]f32{1, 1, 1})
	testing.expect_value(t, _tr(b).scale, [3]f32{2, 2, 2})
	testing.expect_value(t, _tr(b).rotation, b_rotation)
	testing.expect_value(t, len(tween.run_infos()), 0)
}

// The way a preview poses the world for a render only: replay before, unapply
// after. Between the two the world holds authored values, and an edit made
// there becomes the new start.
@(test)
test_unapply_and_replay :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	a := engine.transform_new("A")
	_tr(a).position = {1, 0, 0}

	// Two steps on the same value: the second starts where the first ended.
	s := tween.sequence()
	tween.chain(s, tween.position(a, {1, 4, 0}, 0.25))
	tween.chain(s, tween.position(a, {5, 4, 0}, 0.25))
	tween.set_paused(s, true)
	tween.set_keep_when_done(s, true)

	frame :: proc(h: tween.Handle, dt: f32) -> [3]f32 {
		tween.replay(h)
		tween.tick(h, dt)
		posed := _tr_pos(h)
		tween.unapply(h)
		return posed
	}
	posed := frame(s, 0.125) // half of the first step
	testing.expect(t, _near(posed.y, 2), "the render sees the pose")
	testing.expect_value(t, _tr(a).position, [3]f32{1, 0, 0})

	// An edit between frames moves the start, and the pose follows it.
	_tr(a).position = {1, 0, 2}
	posed = frame(s, 0)
	testing.expect(t, _near(posed.y, 2) && _near(posed.z, 1), "half way from the edited start")
	testing.expect_value(t, _tr(a).position, [3]f32{1, 0, 2})

	// Into the second step: it starts where the first one ends.
	posed = frame(s, 0.125) // the first step ends, the second gets the whole tick
	testing.expect(t, _near(posed.x, 3) && _near(posed.y, 4), "half of the second step")
	testing.expect_value(t, _tr(a).position, [3]f32{1, 0, 2})

	posed = frame(s, 1)
	testing.expect(t, tween.is_done(s))
	testing.expect_value(t, posed, [3]f32{5, 4, 0})
	testing.expect_value(t, _tr(a).position, [3]f32{1, 0, 2})
}

@(private = "file")
_tr_pos :: proc(h: tween.Handle) -> [3]f32 {
	for r in tween.run_infos() do if r.handle == h {
		it := engine.pool_iterator(&engine.ctx_world().transforms)
		for tr, _ in engine.pool_next(&it) do if tr.name == "A" do return tr.position
	}
	return {}
}
