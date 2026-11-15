package tween_sample

// The tween demo (assets/tween_demo.scene). Every cube carries
// the script that moves it, configured in the inspector: select a cube to see
// what it does and with which numbers.
//
// - The same script is on every cube it fits, and only its data differs:
//   DemoTween is on ten cubes (the six eases, the spin, the pulse, the patrol
//   and the Unscaled hop), DemoTweenShake on two (the punch and the shake).
// - A script of its own is for what data cannot say: a custom value (Orbit), a
//   sequence of steps (Sequence) and an authored tree (Tree).
// - Each script animates its own object and starts when the scene awakes.
// - Timing is a tween.Settings field, so the ease, the duration and the cycles
//   are set per cube.
// - A script that repeats by starting again binds its run to its object, so
//   the run stops with the cube and never calls into a freed component.
// - Odin has no closures: a callback gets the component through `user`.

import "core:math"
import input "moonhug:libs/input"
import "moonhug:libs/time"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"

@(private = "file")
_local_position :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	return t.position if t != nil else {}
}

// --- Tween: one transform tween. Most cubes carry this script, and only its
// data differs: which part of the transform, the value and the timing. ----------

// What a DemoTween changes.
Demo_Tween_Part :: enum u8 {
	Position_Offset, // local position, `value` added to where the cube stands
	Scale,           // local scale, to `value`
	Euler_Angles,    // local rotation, to `value` in degrees
	World_Offset,    // world position, `value` added to where the cube stands
}

@(component={menu="Tween Sample/Tween"})
@(typ_guid={guid = "32c4cffb-e7af-4bd6-8cf8-a86961c9f255"})
DemoTween :: struct {
	using base: engine.CompData `inspect:"-"`,
	part:     Demo_Tween_Part,
	value:    [3]f32,
	settings: tween.Settings,
	// The clock the tween runs on. Unscaled keeps its speed in slow motion.
	clock:    time.Clock,
	// Above 0: units per second, in place of the settings' duration. For the
	// two position parts.
	speed:    f32 `decor:min(0)`,
}

type_reset_DemoTween :: proc(d: ^DemoTween) {
	d.value = {0, 2, 0}
	d.settings = {duration = 1, cycles = -1, cycle_mode = .Yoyo}
}

type_cleanup_DemoTween :: proc(d: ^DemoTween) {
	tween.type_cleanup_Settings(&d.settings)
	engine.comp_zero(d)
}

@(comp_awake={component=DemoTween})
comp_awake_DemoTween :: proc(d: ^DemoTween) {
	cube := d.owner
	switch d.part {
	case .Position_Offset:
		tween.position(cube, _local_position(cube) + d.value, &d.settings, opt = {clock = d.clock, speed = d.speed})
	case .Scale:
		tween.scale(cube, d.value, &d.settings, opt = {clock = d.clock})
	case .Euler_Angles:
		tween.euler_angles(cube, d.value, &d.settings, opt = {clock = d.clock})
	case .World_Offset:
		tween.world_position(cube, engine.transform_world_position(cube) + d.value, &d.settings, opt = {clock = d.clock, speed = d.speed})
	}
}

// --- Shake: a shake or a punch of one part of the transform, every `interval`
// seconds. The Punch and the Shake cube carry this script with different data. --

@(component={menu="Tween Sample/Shake"})
@(typ_guid={guid = "51f00c46-15eb-4bae-b8be-b2fe6847e837"})
DemoTweenShake :: struct {
	using base: engine.CompData `inspect:"-"`,
	part:     tween.Shake_Part,
	punch:    bool, // a swing along the strength, in place of a wobble on every axis
	strength: [3]f32,
	duration: f32 `decor:min(0)`,
	interval: f32 `decor:min(0)`,
}

type_reset_DemoTweenShake :: proc(d: ^DemoTweenShake) {
	d.strength = {0.35, 0.35, 0}
	d.duration = 0.7
	d.interval = 2
}

@(comp_awake={component=DemoTweenShake})
comp_awake_DemoTweenShake :: proc(d: ^DemoTweenShake) {
	_demo_shake(d)
}

@(private = "file")
_demo_shake :: proc(user: rawptr) {
	d := cast(^DemoTweenShake)user
	cube := d.owner
	switch d.part {
	case .Position:
		if d.punch do tween.punch_position(cube, d.strength, d.duration)
		else do tween.shake_position(cube, d.strength, d.duration)
	case .Rotation:
		if d.punch do tween.punch_rotation(cube, d.strength, d.duration)
		else do tween.shake_rotation(cube, d.strength, d.duration)
	case .Scale:
		if d.punch do tween.punch_scale(cube, d.strength, d.duration)
		else do tween.shake_scale(cube, d.strength, d.duration)
	}
	// The delay brings the next one. Bound to the cube, it stops with it.
	tween.bind(tween.delay(d.interval, _demo_shake, d), cube)
}

// --- Orbit: any value. An angle from 0 to a full turn, written as a place on
// a circle around where the cube stands. -----------------------------------------

@(component={menu="Tween Sample/Orbit"})
@(typ_guid={guid = "41828ce2-9f48-4bf6-8c2d-f6c7c737de11"})
DemoTweenOrbit :: struct {
	using base: engine.CompData `inspect:"-"`,
	radius:   f32 `decor:min(0)`,
	settings: tween.Settings,

	center: [3]f32 `json:"-" inspect:"-"`,
}

type_reset_DemoTweenOrbit :: proc(d: ^DemoTweenOrbit) {
	d.radius = 1.2
	d.settings = {duration = 3, cycles = -1}
}

type_cleanup_DemoTweenOrbit :: proc(d: ^DemoTweenOrbit) {
	tween.type_cleanup_Settings(&d.settings)
	engine.comp_zero(d)
}

@(comp_awake={component=DemoTweenOrbit})
comp_awake_DemoTweenOrbit :: proc(d: ^DemoTweenOrbit) {
	d.center = _local_position(d.owner)
	// custom has no object, so nothing ends it with the cube: bind does.
	tween.bind(tween.custom(0, math.TAU, &d.settings, _demo_orbit, d), d.owner)
}

@(private = "file")
_demo_orbit :: proc(angle: f32, user: rawptr) {
	d := cast(^DemoTweenOrbit)user
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(d.owner))
	if t == nil do return
	t.position = d.center + {math.cos(angle) * d.radius, 0, math.sin(angle) * d.radius}
}

// --- Sequence: steps built one by one. Up, back while turning, down, a pause,
// home. It plays once, so its completion starts the next one. --------------------

@(component={menu="Tween Sample/Sequence"})
@(typ_guid={guid = "ef376249-b82d-4315-b57c-ba48ce17b67d"})
DemoTweenSequence :: struct {
	using base: engine.CompData `inspect:"-"`,
	height: f32,
	depth:  f32,
	pause:  f32 `decor:min(0)`,

	home: [3]f32 `json:"-" inspect:"-"`,
}

type_reset_DemoTweenSequence :: proc(d: ^DemoTweenSequence) {
	d.height = 2
	d.depth = 2
	d.pause = 0.4
}

@(comp_awake={component=DemoTweenSequence})
comp_awake_DemoTweenSequence :: proc(d: ^DemoTweenSequence) {
	d.home = _local_position(d.owner)
	_demo_sequence(d)
}

@(private = "file")
_demo_sequence :: proc(user: rawptr) {
	d := cast(^DemoTweenSequence)user
	cube := d.owner
	up := d.home + {0, d.height, 0}
	back := [3]f32{0, 0, -d.depth}

	s := tween.sequence()
	tween.chain(s, tween.position(cube, up, 0.5, .Back_Out))
	tween.chain(s, tween.position(cube, up + back, 0.5, .Quad_In_Out))
	tween.group(s, tween.euler_angles(cube, {0, 90, 0}, 0.5, .Quad_In_Out)) // with the move
	tween.chain(s, tween.position(cube, d.home + back, 0.4, .Bounce_Out))
	tween.chain_delay(s, d.pause)
	tween.chain(s, tween.position(cube, d.home, 0.5, .Quad_In_Out))
	tween.group(s, tween.euler_angles(cube, {0, 0, 0}, 0.5, .Quad_In_Out))
	tween.chain_delay(s, d.pause)
	tween.on_complete(s, _demo_sequence, d)
	tween.bind(s, cube)
}

// --- Tree: an authored tween tree. This object is the default subject, and a
// node that names its own subject in the tree animates that object. -------------

@(component={menu="Tween Sample/Tree"})
@(typ_guid={guid = "21531c85-204a-4bf8-95cd-3cc900d1882b"})
DemoTweenTree :: struct {
	using base: engine.CompData `inspect:"-"`,
	tree: tween.Authored,
}

type_cleanup_DemoTweenTree :: proc(d: ^DemoTweenTree) {
	tween.authored_destroy(&d.tree)
	engine.comp_zero(d)
}

@(comp_awake={component=DemoTweenTree})
comp_awake_DemoTweenTree :: proc(d: ^DemoTweenTree) {
	_demo_tree(d)
}

@(private = "file")
_demo_tree :: proc(user: rawptr) {
	d := cast(^DemoTweenTree)user
	h := tween.run(&d.tree, tween.TweenContext{subject = d.owner})
	tween.on_complete(h, _demo_tree, d)
	tween.bind(h, d.owner)
}

// --- Controls: T toggles slow motion for the whole game. A cube whose tween
// runs on the Unscaled clock keeps its speed. ------------------------------------

@(component={max=1, menu="Tween Sample/Controls"})
@(typ_guid={guid = "027bb12f-1a6c-4c0c-8051-141eb8013664"})
DemoTweenControls :: struct {
	using base: engine.CompData `inspect:"-"`,
	slow_scale: f32 `decor:range(0, 1)`,
}

type_reset_DemoTweenControls :: proc(d: ^DemoTweenControls) {
	d.slow_scale = 0.2
}

@(comp_update={component=DemoTweenControls})
comp_update_DemoTweenControls :: proc(dt: f32, d: ^DemoTweenControls) {
	if input.key_released(.T) do time.set_time_scale(d.slow_scale if time.time_scale() == 1 else 1)
}

@(comp_on_destroy={component=DemoTweenControls})
comp_on_destroy_DemoTweenControls :: proc(d: ^DemoTweenControls) {
	time.set_time_scale(1)
}
