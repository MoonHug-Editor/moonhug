package tween

// Tweens from code: one call starts a tween, and a sequence is built step by
// step. Nothing is authored and nothing is parsed: the calls make the same
// pooled nodes an authored tree runs as, and return the same Handle.
//
//   tween.position(door, {0, 2, 0}, 0.3, .Back_Out)
//   tween.custom(0, 1, 0.5, set_alpha, panel)
//   tween.delay(2, explode, bomb)
//
//   s := tween.sequence()
//   tween.chain(s, tween.position(door, {0, 2, 0}, 0.3))
//   tween.group(s, tween.scale(door, {1.2, 1.2, 1.2}, 0.3))   // with the move
//   tween.chain_delay(s, 1)
//   tween.chain_callback(s, door_opened, door)
//
// - Odin has no closures: a callback is a proc plus a `user` pointer.
// - A step handed to a sequence stops being a run of its own. Its handle is
//   dead from then on, and the sequence's handle controls it.
// - A step joins a sequence before it has ticked, so a sequence is built in
//   the frame it starts in.

import "base:runtime"
import "core:math/linalg"
import "moonhug:libs/time"
import engine "moonhug:packages/engine"

// What a tween started from code may set besides its end value, duration and
// ease. The zero value is: play once, no delay, on Update.
Options :: struct {
	cycles:     i32,          // 0 and 1 play once, -1 repeats until stopped or completed
	cycle_mode: Cycle_Mode,
	delay:      f32,          // seconds before it starts
	clock:      time.Clock,   // the clock it ticks on
	curve:      ^engine.Curve, // set: the ease is this curve, copied
	// Above 0: the tween moves at this many units per second and its duration
	// argument is ignored. For position tweens, custom and field.
	speed:      f32,
}

// A tween's timing as one inspector field: a component declares
// `move: tween.Settings`, the scene sets it, and the code passes `&d.move`
// where a one-line tween takes its duration.
//
//   tween.position(door, {0, 2, 0}, &d.move)
@(typ_guid={guid="1152800f-1bf5-48df-ba12-745f6571e5ae"})
Settings :: struct {
	duration:   f32 `decor:min(0)`,
	ease:       Ease,
	curve:      engine.Curve, // the shape when ease is Curve
	// 0 and 1 play once, -1 repeats until stopped or completed.
	cycles:     i32,
	cycle_mode: Cycle_Mode,
	delay:      f32 `decor:min(0)`,
}

type_cleanup_Settings :: proc(s: ^Settings) {
	delete(s.curve.keys)
	s^ = {}
}

// How long a one-line tween takes: seconds, or the settings a component
// holds. With settings, the ease, cycles, cycle mode and delay come from them
// and the call's own `ease` argument is not used.
Timing :: union {
	f32,
	^Settings,
}

// The duration, ease and options a one-line tween runs with, from what the
// call was given. A plugin's own one-line tween resolves its timing here.
timing_resolve :: proc(timing: Timing, ease: Ease, opt: Options) -> (duration: f32, e: Ease, o: Options) {
	o = opt
	switch t in timing {
	case f32:
		return t, ease, o
	case ^Settings:
		assert(t != nil, "tween: the settings pointer is nil")
		o.cycles = t.cycles
		o.cycle_mode = t.cycle_mode
		o.delay = t.delay
		if t.ease == .Curve do o.curve = &t.curve
		return t.duration, t.ease, o
	}
	return 0, ease, o
}

// --- One-line tweens ---------------------------------------------------------------

// Moves the object's local position from where it is to `to`.
position :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
	d, e, o := timing_resolve(timing, ease, opt)
	h, node := node_new(TweenMoveToLocal)
	node.position = to
	node.duration = d
	node.speed = o.speed
	return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Scales the object from its local scale to `to`.
scale :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
	d, e, o := timing_resolve(timing, ease, opt)
	assert(o.speed == 0, "tween.scale: no speed option, give a duration")
	h, node := node_new(TweenScaleToLocal)
	node.scale = to
	node.duration = d
	return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Rotates the object from its local rotation to the quaternion `to`, along
// the shortest arc.
rotation :: proc(target: engine.Transform_Handle, to: [4]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
	d, e, o := timing_resolve(timing, ease, opt)
	assert(o.speed == 0, "tween.rotation: no speed option, give a duration")
	h, node := node_new(TweenRotateToLocal)
	node.rotation = to
	node.duration = d
	return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Rotates the object from its local rotation to Euler angles in degrees.
euler_angles :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
	return rotation(target, engine.quat_from_euler_xyz(to.x, to.y, to.z), timing, ease, opt)
}

// Animates any value: `set` is called every tick with the value between
// `from` and `to`, and with `user`. One form per width: a number, or a
// vector of 2, 3 or 4 numbers (a color is 4).
custom :: proc {
	custom_f32,
	custom_vec2,
	custom_vec3,
	custom_vec4,
}

custom_f32 :: proc(from, to: f32, timing: Timing, set: proc(value: f32, user: rawptr), user: rawptr = nil, ease := Ease.Linear, opt := Options{}) -> Handle {
	return _start_custom({from, 0, 0, 0}, {to, 0, 0, 0}, 1, rawptr(set), timing, user, ease, opt)
}

custom_vec2 :: proc(from, to: [2]f32, timing: Timing, set: proc(value: [2]f32, user: rawptr), user: rawptr = nil, ease := Ease.Linear, opt := Options{}) -> Handle {
	return _start_custom({from.x, from.y, 0, 0}, {to.x, to.y, 0, 0}, 2, rawptr(set), timing, user, ease, opt)
}

custom_vec3 :: proc(from, to: [3]f32, timing: Timing, set: proc(value: [3]f32, user: rawptr), user: rawptr = nil, ease := Ease.Linear, opt := Options{}) -> Handle {
	return _start_custom({from.x, from.y, from.z, 0}, {to.x, to.y, to.z, 0}, 3, rawptr(set), timing, user, ease, opt)
}

custom_vec4 :: proc(from, to: [4]f32, timing: Timing, set: proc(value: [4]f32, user: rawptr), user: rawptr = nil, ease := Ease.Linear, opt := Options{}) -> Handle {
	return _start_custom(from, to, 4, rawptr(set), timing, user, ease, opt)
}

// Waits `seconds`, then calls `call` with `user`. With no call it is a
// run that only takes time: something to chain after or wait for.
delay :: proc(seconds: f32, call: proc(user: rawptr) = nil, user: rawptr = nil, clock := time.Clock.Update) -> Handle {
	return run_node(_callback_node(seconds, call, user), {}, clock)
}

// --- Sequences -----------------------------------------------------------------------

// Starts an empty sequence. chain, group and insert put steps into it.
sequence :: proc(clock := time.Clock.Update) -> Handle {
	context.allocator = runtime.default_allocator()
	root_h, root := node_new(Parallel)
	chain_h, _ := node_new(Sequence)
	append(&root.children, chain_h)
	h := run_node(root_h, {}, clock)
	r := _run_ptr(h)
	r.built = true
	r.chain = chain_h
	r.group = NIL_NODE
	return h
}

// Puts `step` after everything chained so far.
chain :: proc(seq: Handle, step: Handle) {
	context.allocator = runtime.default_allocator()
	node := _take(step)
	r := _built(seq)
	append(node_children(r.chain), node)
	r.group = NIL_NODE
	_relength(r)
}

// Puts `step` next to the last chained step: both start together, and the
// sequence goes on when both are done.
group :: proc(seq: Handle, step: Handle) {
	context.allocator = runtime.default_allocator()
	node := _take(step)
	r := _built(seq)
	steps := node_children(r.chain)
	if r.group != NIL_NODE {
		append(node_children(r.group), node)
	} else if len(steps) == 0 {
		append(steps, node)
	} else {
		group_h, group_node := node_new(Parallel)
		append(&group_node.children, steps[len(steps) - 1], node)
		steps[len(steps) - 1] = group_h
		r.group = group_h
	}
	_relength(r)
}

// Puts `step` at `at` seconds from the sequence's start, whatever is
// chained.
insert :: proc(seq: Handle, at: f32, step: Handle) {
	context.allocator = runtime.default_allocator()
	node := _take(step)
	r := _built(seq)
	node_base(node).delay += at
	append(node_children(r.root), node)
	_relength(r)
}

// Chains a pause of `seconds`.
chain_delay :: proc(seq: Handle, seconds: f32) {
	_chain_node(seq, _callback_node(seconds, nil, nil))
}

// Chains a call: `call` runs with `user` when the sequence gets there.
chain_callback :: proc(seq: Handle, call: proc(user: rawptr), user: rawptr = nil) {
	_chain_node(seq, _callback_node(0, call, user))
}

// Calls `call` with `user` at `at` seconds from the sequence's start.
insert_callback :: proc(seq: Handle, at: f32, call: proc(user: rawptr), user: rawptr = nil) {
	context.allocator = runtime.default_allocator()
	r := _built(seq)
	append(node_children(r.root), _callback_node(at, call, user))
	_relength(r)
}

// Chains a wait: the sequence holds there until `until` returns true. A
// sequence with a wait has no progress, and complete does not wait for it.
chain_wait_until :: proc(seq: Handle, until: proc(user: rawptr) -> bool, user: rawptr = nil) {
	h, node := node_new(TweenWaitUntil)
	node.until = until
	node.user = user
	_chain_node(seq, h)
}

// --- The nodes code makes --------------------------------------------------------------

// A value node over up to four numbers, written through a proc.
@(typ_guid={guid="75176d71-8682-4dbc-8277-3c1c3ee55731"})
TweenCustom :: struct {
	using base: Tween `inline:""`,
	using anim: Tween_Anim `inline:""`,
	duration: f32,

	from:    [4]f32 `json:"-" inspect:"-"`,
	to:      [4]f32 `json:"-" inspect:"-"`,
	width:   u8 `json:"-" inspect:"-"`,     // how many of the four numbers the setter takes
	set_raw: rawptr `json:"-" inspect:"-"`, // the setter, typed by width
	user:    rawptr `json:"-" inspect:"-"`,
}

type_cleanup_TweenCustom :: proc(self: ^TweenCustom) {
	type_cleanup_Tween_Anim(&self.anim)
	self^ = {}
}

begin_TweenCustom :: proc(self: ^TweenCustom, ctx: TweenContext) -> bool {
	return self.set_raw != nil
}

apply_TweenCustom :: proc(self: ^TweenCustom, t: f32, ctx: TweenContext) {
	v := self.from + (self.to - self.from) * t
	switch self.width {
	case 1: (cast(proc(value: f32, user: rawptr))self.set_raw)(v.x, self.user)
	case 2: (cast(proc(value: [2]f32, user: rawptr))self.set_raw)(v.xy, self.user)
	case 3: (cast(proc(value: [3]f32, user: rawptr))self.set_raw)(v.xyz, self.user)
	case 4: (cast(proc(value: [4]f32, user: rawptr))self.set_raw)(v, self.user)
	}
}

// Waits its delay, then calls `call` once. With no call it is a pause.
@(typ_guid={guid="37c9131e-ab5b-47c6-85df-dead720ad53b"})
TweenCallback :: struct {
	using base: Tween `inline:""`,
	call: proc(user: rawptr) `json:"-" inspect:"-"`,
	user: rawptr `json:"-" inspect:"-"`,
}

tick_TweenCallback :: proc(self: ^TweenCallback, dt: f32, ctx: TweenContext) -> Status {
	if has_delay(&self.base, dt) do return .Running
	if self.call != nil do self.call(self.user)
	return .Done
}

// Holds until `until` returns true.
@(typ_guid={guid="62dbdb7b-297f-4c51-a274-2ec5c238c65c"})
TweenWaitUntil :: struct {
	using base: Tween `inline:""`,
	until: proc(user: rawptr) -> bool `json:"-" inspect:"-"`,
	user:  rawptr `json:"-" inspect:"-"`,
}

tick_TweenWaitUntil :: proc(self: ^TweenWaitUntil, dt: f32, ctx: TweenContext) -> Status {
	if has_delay(&self.base, dt) do return .Running
	// complete does not wait for the world.
	if _completing || self.until == nil || self.until(self.user) do return .Done
	return .Running
}

// Called from register_builtin_nodes.
register_code_nodes :: proc() {
	register_tween(TweenCustom, begin_TweenCustom, apply_TweenCustom, code_only = true)
	register_node(TweenCallback, tick_TweenCallback, .Instant, code_only = true)
	register_node(TweenWaitUntil, tick_TweenWaitUntil, .Unknown, code_only = true)
}

// --- Internals -----------------------------------------------------------------------------

@(private = "file")
_start_custom :: proc(from, to: [4]f32, width: u8, set_raw: rawptr, timing: Timing, user: rawptr, ease: Ease, opt: Options) -> Handle {
	assert(set_raw != nil, "tween.custom: needs a proc that takes the value")
	d, e, o := timing_resolve(timing, ease, opt)
	h, node := node_new(TweenCustom)
	node.from = from
	node.to = to
	node.width = width
	node.set_raw = set_raw
	node.user = user
	node.duration = d
	if o.speed > 0 do node.duration = linalg.length(to - from) / o.speed
	return start_value_node(h, &node.base, &node.anim, {}, e, o)
}

@(private = "file")
_callback_node :: proc(seconds: f32, call: proc(user: rawptr), user: rawptr) -> Node_Handle {
	h, node := node_new(TweenCallback)
	node.delay = seconds
	node.call = call
	node.user = user
	return h
}

@(private = "file")
_chain_node :: proc(seq: Handle, node: Node_Handle) {
	context.allocator = runtime.default_allocator()
	r := _built(seq)
	append(node_children(r.chain), node)
	r.group = NIL_NODE
	_relength(r)
}

// The run of a sequence made by sequence().
@(private = "file")
_built :: proc(seq: Handle) -> ^_Run {
	r := _run_ptr(seq)
	assert(r != nil, "tween: the sequence is not alive")
	assert(r.built, "tween: steps go into a run made by tween.sequence()")
	assert(!r.ticking, "tween: a sequence does not change from inside its own tick")
	return r
}

// Takes the tree out of a run that has not ticked yet and ends that run
// without a word: the tree is about to live in a sequence.
@(private = "file")
_take :: proc(step: Handle) -> Node_Handle {
	r := _run_ptr(step)
	assert(r != nil, "tween: the step is not a live tween (did it fail to start, or is it chained already?)")
	assert(r.elapsed == 0 && !r.ticking, "tween: a step joins a sequence before it has ticked")
	root := r.root
	// The step keeps the subject it was started with.
	node_set_default_target(root, r.ctx.subject)
	r^ = _Run{generation = r.generation + 1}
	append(&_free_runs, step.index)
	return root
}

@(private = "file")
_relength :: proc(r: ^_Run) {
	r.length, r.length_known = node_length(r.root)
}
