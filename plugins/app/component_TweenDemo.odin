package app

// The tween demo (assets/demo_tweens/demo_tweens.scene): one cube per example
// of the tween plugin's code API, plus one authored tree. Everything starts
// when the scene awakes and repeats until the scene goes.
//
// - The cubes are picked in the inspector. The code never looks one up by name.
// - `hop` and `spin` are tween.Settings fields: change a duration, an ease or
//   a cycle mode in the inspector and press Play again.
// - `tree` is authored in the scene. The code starts it on `tree_actor`, and
//   one of its nodes names another cube as its own subject.
// - T toggles slow motion. The Unscaled cube keeps its speed.

import "core:math"
import input "moonhug:libs/input"
import "moonhug:libs/time"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"

@(component={max=1, menu="Demo/TweenDemo"})
@(typ_guid={guid = "0c9da377-de19-48f9-a4ff-a7a659a98fc9"})
TweenDemo :: struct {
	using base: engine.CompData `inspect:"-"`,

	// One cube per ease, in the order of TWEEN_DEMO_EASES. They hop with `hop`.
	ease_cubes: [dynamic]engine.Ref_Local `ref:"Transform"`,
	hop:        tween.Settings,

	spin_cube:     engine.Ref_Local `ref:"Transform"`,
	spin:          tween.Settings,
	pulse_cube:    engine.Ref_Local `ref:"Transform"`,
	punch_cube:    engine.Ref_Local `ref:"Transform"`,
	shake_cube:    engine.Ref_Local `ref:"Transform"`,
	sequence_cube: engine.Ref_Local `ref:"Transform"`,
	orbit_cube:    engine.Ref_Local `ref:"Transform"`,
	speed_cube:    engine.Ref_Local `ref:"Transform"`,
	unscaled_cube: engine.Ref_Local `ref:"Transform"`,

	// An authored tree. It runs on tree_actor, except the nodes that name
	// their own subject.
	tree:       tween.Authored,
	tree_actor: engine.Ref_Local `ref:"Transform"`,

	// Where the orbit cube circles around: its place when the scene awakes.
	orbit_center: [3]f32 `json:"-" inspect:"-"`,
}

// The eases of the hopping row, left to right.
TWEEN_DEMO_EASES :: [?]tween.Ease{.Linear, .Quad_In_Out, .Back_In_Out, .Bounce_Out, .Elastic_Out, .Expo_In_Out}

type_reset_TweenDemo :: proc(d: ^TweenDemo) {
	d.hop = {duration = 1, cycles = -1, cycle_mode = .Yoyo}
	d.spin = {duration = 1, cycles = -1, cycle_mode = .Incremental}
}

type_cleanup_TweenDemo :: proc(d: ^TweenDemo) {
	delete(d.ease_cubes)
	tween.type_cleanup_Settings(&d.hop)
	tween.type_cleanup_Settings(&d.spin)
	tween.authored_destroy(&d.tree)
	engine.comp_zero(d)
}

@(private = "file")
_cube :: proc(r: engine.Ref_Local) -> engine.Transform_Handle {
	return engine.Transform_Handle(r.handle)
}

@(private = "file")
_local_position :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	return t.position if t != nil else {}
}

@(comp_awake={component=TweenDemo})
comp_awake_TweenDemo :: proc(d: ^TweenDemo) {
	// Eases: the same hop, one ease per cube. The settings come from the
	// inspector, only the ease differs per cube.
	for ease, i in TWEEN_DEMO_EASES {
		if i >= len(d.ease_cubes) do break
		cube := _cube(d.ease_cubes[i])
		hop := d.hop
		if hop.ease != .Curve do hop.ease = ease
		tween.position(cube, _local_position(cube) + {0, 2, 0}, &hop)
	}

	// Spin: Incremental cycles keep turning by the same angle.
	tween.euler_angles(_cube(d.spin_cube), {0, 120, 0}, &d.spin)

	// Pulse: scale out and back, forever.
	tween.scale(_cube(d.pulse_cube), {1.5, 1.5, 1.5}, 0.6, .Sine_In_Out, {cycles = -1, cycle_mode = .Yoyo})

	// Speed: units per second in place of a duration, in world space.
	speed_cube := _cube(d.speed_cube)
	tween.world_position(speed_cube, engine.transform_world_position(speed_cube) + {0, 0, 4}, 0, .Sine_In_Out, {speed = 2, cycles = -1, cycle_mode = .Yoyo})

	// Unscaled: this one ignores the game's time scale (press T).
	unscaled_cube := _cube(d.unscaled_cube)
	tween.position(unscaled_cube, _local_position(unscaled_cube) + {0, 2, 0}, 0.8, .Quad_In_Out, {cycles = -1, cycle_mode = .Yoyo, clock = .Unscaled})

	// Any value: an angle from 0 to a full turn, written as a place on a circle.
	d.orbit_center = _local_position(_cube(d.orbit_cube))
	tween.custom(0, math.TAU, 3, _tween_demo_orbit, d, opt = {cycles = -1})

	_tween_demo_punch(d)
	_tween_demo_shake(d)
	_tween_demo_sequence(d)
	_tween_demo_tree(d)
}

@(comp_on_destroy={component=TweenDemo})
comp_on_destroy_TweenDemo :: proc(d: ^TweenDemo) {
	time.set_time_scale(1)
}

@(comp_update={component=TweenDemo})
comp_update_TweenDemo :: proc(dt: f32, d: ^TweenDemo) {
	if input.key_released(.T) do time.set_time_scale(0.2 if time.time_scale() == 1 else 1)
}

// custom's setter: there are no closures, so the component travels in `user`.
@(private = "file")
_tween_demo_orbit :: proc(angle: f32, user: rawptr) {
	d := cast(^TweenDemo)user
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(_cube(d.orbit_cube)))
	if t == nil do return
	t.position = d.orbit_center + {math.cos(angle) * 1.2, 0, math.sin(angle) * 1.2}
}

// A punch every 1.5 seconds. The delay that brings the next one is bound to
// this object, so it stops with the scene and never calls into a freed
// component.
@(private = "file")
_tween_demo_punch :: proc(user: rawptr) {
	d := cast(^TweenDemo)user
	tween.punch_scale(_cube(d.punch_cube), {0.6, 0.6, 0.6}, 0.6)
	tween.bind(tween.delay(1.5, _tween_demo_punch, d), d.owner)
}

@(private = "file")
_tween_demo_shake :: proc(user: rawptr) {
	d := cast(^TweenDemo)user
	tween.shake_position(_cube(d.shake_cube), {0.35, 0.35, 0}, 0.7)
	tween.bind(tween.delay(2, _tween_demo_shake, d), d.owner)
}

// A sequence built step by step: up, turn while moving back, down, a pause.
// It plays once, so its completion starts the next one.
@(private = "file")
_tween_demo_sequence :: proc(user: rawptr) {
	d := cast(^TweenDemo)user
	cube := _cube(d.sequence_cube)
	home := _local_position(cube)
	s := tween.sequence()
	tween.chain(s, tween.position(cube, home + {0, 2, 0}, 0.5, .Back_Out))
	tween.chain(s, tween.position(cube, home + {0, 2, -2}, 0.5, .Quad_In_Out))
	tween.group(s, tween.euler_angles(cube, {0, 90, 0}, 0.5, .Quad_In_Out))
	tween.chain(s, tween.position(cube, home + {0, 0, -2}, 0.4, .Bounce_Out))
	tween.chain_delay(s, 0.3)
	tween.chain(s, tween.position(cube, home, 0.5, .Quad_In_Out))
	tween.group(s, tween.euler_angles(cube, {0, 0, 0}, 0.5, .Quad_In_Out))
	tween.chain_delay(s, 0.4)
	tween.on_complete(s, _tween_demo_sequence, d)
	tween.bind(s, d.owner)
}

// The authored tree: tree_actor is the default object, and the node that has
// its own subject in the scene animates that cube.
@(private = "file")
_tween_demo_tree :: proc(user: rawptr) {
	d := cast(^TweenDemo)user
	h := tween.run(&d.tree, tween.TweenContext{subject = _cube(d.tree_actor)})
	tween.on_complete(h, _tween_demo_tree, d)
	tween.bind(h, d.owner)
}
