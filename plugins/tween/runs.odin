package tween

// Runs: the live tweens and the handle that controls one.
//
// - run instantiates an authored tree and returns a Handle. The
//   zero handle is "no run": every proc here accepts it and a dead handle.
// - A run ticks on a clock (moonhug/libs/time), `Update` unless run names
//   another. tween_update ticks the runs on per-frame clocks,
//   tween_fixed_update the runs on fixed-tick clocks.
// - A run ends in one of three ways:
//   - it finishes: its tree is done. on_complete is called.
//   - complete: every value jumps to its end. on_complete is called.
//   - stop: values stay where they are. on_complete is not called.
// - Nothing ties a run to an object unless bind says so. A bound run
//   stops when its object is destroyed and waits while the object is inactive.
// - Play ending stops every run.
//
// The prototype library (register) keeps named trees as marshaled JSON,
// so run("name") starts a fresh copy each time.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "moonhug:libs/time"
import engine "moonhug:packages/engine"

// One live run. The zero value is no run.
Handle :: struct {
	index:      u32,
	generation: u32,
}

@(private)
_Run :: struct {
	root:           Node_Handle,
	ctx:            TweenContext,
	clock:          time.Clock,
	generation:     u32,
	alive:          bool,
	paused:         bool,
	ticking:        bool, // inside its own tick: a stop waits for the tick to return
	stop_requested: bool,
	time_scale:     f32,
	elapsed:        f32,
	length:         f32,
	length_known:   bool,
	bound:          bool,
	owner:          engine.Transform_Handle,
	on_complete:    proc(user: rawptr),
	user:           rawptr,
	on_event:       proc(name: string, user: rawptr),
	event_user:     rawptr,
	hold:           bool, // stays alive when its tree is done (set_hold)
	done:           bool, // its tree is done and the run is held
	waits_on:       Handle, // holds until that run has ended (wait_for)

	// A sequence built from code (code.odin): the root is a Parallel whose
	// first child is the Sequence the chained steps go into.
	built:          bool,
	chain:          Node_Handle,
	group:          Node_Handle, // the Parallel the last step sits in, NIL_NODE = none
}

// Slots are reused through _free_runs. A slot's generation starts at 1 and
// grows each time its run ends, so an old handle never reaches a new run.
@(private) _runs:      [dynamic]_Run
@(private) _free_runs: [dynamic]u32

// True while complete drives a tree to its end (has_delay and the
// value node tick read it).
@(private) _completing: bool

// The step complete ticks with: longer than any authored tree.
@(private) _COMPLETE_DT :: f32(1e9)
// A tree that is not done after this many such steps never ends by itself.
@(private) _COMPLETE_MAX_TICKS :: 64

// Named prototypes as marshaled JSON — instantiated fresh per run, so two
// runs of "Anim0" never share nodes. Map, keys and payloads live on the
// default allocator: entries outlive any caller frame, and a temp-allocated
// key dangles after a frame's free_all.
@(private) _lib: map[string][]byte

@(init)
_runs_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	_lib = make(map[string][]byte, alloc)
	_runs = make([dynamic]_Run, alloc)
	_free_runs = make([dynamic]u32, alloc)
}

// The player's startup. The editor and the tests call it where they need it.
@(phase={key=Init, mode=App})
tween_init :: proc() {
	register_builtin_nodes()
}

// Registers a prototype under `key`, replacing one already there: a
// re-registration after an edit (every Simulate) takes the new value.
register :: proc(key: string, a: ^Authored) {
	context.allocator = runtime.default_allocator()
	data, err := json.marshal(a.value, {spec = .JSON})
	if err != nil do return
	if old, has := _lib[key]; has {
		delete(old)
		_lib[key] = data
		return
	}
	_lib[strings.clone(key)] = data
}

library_count :: proc() -> int {
	return len(_lib)
}

// --- Starting a run ---------------------------------------------------------------

// Starts an authored tween and returns its handle: the zero handle when
// nothing started (an unknown name, an unknown node type, a skipped root, a
// node subject that names no object).
//
// `ctx.subject` is the default object: every node animates it, except a node
// whose own `subject` is set in the inspector, which animates that one.
run :: proc {
	run_key,
	run_authored,
}

run_key :: proc(key: string, ctx: TweenContext, clock := time.Clock.Update) -> Handle {
	raw, ok := _lib[key]
	if !ok do return {}
	prev := context.allocator
	context.allocator = context.temp_allocator
	val, perr := json.parse(raw, .JSON, true)
	context.allocator = prev
	if perr != nil do return {}
	return run_value(val, ctx, clock)
}

run_authored :: proc(a: ^Authored, ctx: TweenContext, clock := time.Clock.Update) -> Handle {
	return run_value(a.value, ctx, clock)
}

// Instantiates and starts a tree from its authored value (not consumed).
run_value :: proc(v: json.Value, ctx: TweenContext, clock := time.Clock.Update) -> Handle {
	root, ok := _instantiate(v)
	if !ok do return {}
	base := node_base(root)
	if base != nil && base.skip {
		node_destroy(root)
		return {}
	}
	// The root's own clock, set in the inspector, wins over the code's.
	clock := clock
	if base != nil && base.own_clock do clock = base.clock
	// A node's own subject, set in the inspector, wins over the run's.
	scene: ^engine.Scene
	if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(ctx.subject)); t != nil do scene = t.scene
	if !node_resolve_subjects(root, scene) {
		node_destroy(root)
		return {}
	}
	return run_node(root, ctx, clock)
}

// Starts a run over a live tree the caller built (node_new). The run owns
// the tree from here.
run_node :: proc(root: Node_Handle, ctx: TweenContext, clock := time.Clock.Update) -> Handle {
	context.allocator = runtime.default_allocator()
	index: u32
	if len(_free_runs) > 0 {
		index = pop(&_free_runs)
	} else {
		index = u32(len(_runs))
		append(&_runs, _Run{generation = 1})
	}
	r := &_runs[index]
	r^ = _Run {
		root       = root,
		ctx        = ctx,
		clock      = clock,
		generation = r.generation,
		alive      = true,
		time_scale = 1,
	}
	r.length, r.length_known = node_length(root)
	return Handle{index = index, generation = r.generation}
}

// --- Controlling a run --------------------------------------------------------------

@(private)
_run_ptr :: proc(h: Handle) -> ^_Run {
	if h.generation == 0 || int(h.index) >= len(_runs) do return nil
	r := &_runs[h.index]
	if !r.alive || r.generation != h.generation do return nil
	return r
}

// True until the run finishes, is completed or is stopped.
is_alive :: proc(h: Handle) -> bool {
	return _run_ptr(h) != nil
}

// Ends the run where it is: values stay, on_complete is not called.
stop :: proc(h: Handle) {
	r := _run_ptr(h)
	if r == nil do return
	if r.ticking {
		r.stop_requested = true
		return
	}
	_run_end(h.index, false)
}

// Ends the run at its end: every value node jumps to its last value, an
// endless node to the end of the cycle it is in, and on_complete is called.
// A node that never ends by itself is cut off.
complete :: proc(h: Handle) {
	r := _run_ptr(h)
	if r == nil do return
	assert(!r.ticking, "tween.complete: called from inside this run's own tick")
	root, ctx := r.root, r.ctx
	ctx.run = h
	_completing = true
	for _ in 0 ..< _COMPLETE_MAX_TICKS {
		if tick_node(root, _COMPLETE_DT, ctx) == .Done do break
	}
	_completing = false
	_run_end(h.index, true)
}

// A paused run keeps its place and does not advance.
set_paused :: proc(h: Handle, paused: bool) {
	if r := _run_ptr(h); r != nil do r.paused = paused
}

is_paused :: proc(h: Handle) -> bool {
	r := _run_ptr(h)
	return r != nil && r.paused
}

// The run's own speed on top of its clock: 1 by default, 0 holds it.
set_time_scale :: proc(h: Handle, scale: f32) {
	assert(scale >= 0, "tween.set_time_scale: a run does not go backwards")
	if r := _run_ptr(h); r != nil do r.time_scale = scale
}

time_scale :: proc(h: Handle) -> f32 {
	r := _run_ptr(h)
	return r.time_scale if r != nil else 0
}

// The clock the run ticks on.
clock_of :: proc(h: Handle) -> time.Clock {
	r := _run_ptr(h)
	return r.clock if r != nil else .Update
}

// Seconds the run has advanced.
elapsed :: proc(h: Handle) -> f32 {
	r := _run_ptr(h)
	return r.elapsed if r != nil else 0
}

// How far the run is, 0 at the start and 1 at the end. `ok` is false for a
// dead handle and for a run whose length cannot be told (node_length).
progress :: proc(h: Handle) -> (progress: f32, ok: bool) {
	r := _run_ptr(h)
	if r == nil || !r.length_known do return 0, false
	if r.length <= 0 do return 1, true
	return clamp(r.elapsed / r.length, 0, 1), true
}

// Sets the proc called once when the run finishes or is completed. It is not
// called when the run is stopped. The run is already gone when it runs, so it
// may start the next one.
on_complete :: proc(h: Handle, on_complete: proc(user: rawptr), user: rawptr = nil) {
	if r := _run_ptr(h); r != nil {
		r.on_complete = on_complete
		r.user = user
	}
}

// Sets the proc called when the run reaches a TweenEvent node, with the
// node's name. It is how an authored tree calls into code.
on_event :: proc(h: Handle, on_event: proc(name: string, user: rawptr), user: rawptr = nil) {
	if r := _run_ptr(h); r != nil {
		r.on_event = on_event
		r.event_user = user
	}
}

// Called by a TweenEvent node: hands the name to the run's on_event proc.
event_emit :: proc(h: Handle, name: string) {
	r := _run_ptr(h)
	if r == nil || r.on_event == nil do return
	r.on_event(name, r.event_user)
}

// Ticks one run by `dt` seconds, whatever its clock, paused or not. For
// previews and for stepping a run by hand.
tick :: proc(h: Handle, dt: f32) {
	r := _run_ptr(h)
	if r == nil do return
	was_paused := r.paused
	_tick_run(h.index, dt)
	if r = _run_ptr(h); r != nil do r.paused = was_paused
}

// A held run stays alive when its tree is done, with every value at its end,
// until it is stopped or rewound. on_complete waits for that too and is then
// not called. A preview holds its run so it can still put things back.
set_hold :: proc(h: Handle, hold: bool) {
	if r := _run_ptr(h); r != nil do r.hold = hold
}

// True when a held run's tree is done.
is_done :: proc(h: Handle) -> bool {
	r := _run_ptr(h)
	return r != nil && r.done
}

// Ends the run and puts back what it changed: every value it animated is
// where it was when the run began to animate it. on_complete is not called.
rewind :: proc(h: Handle) {
	r := _run_ptr(h)
	if r == nil do return
	assert(!r.ticking, "tween.rewind: called from inside this run's own tick")
	ctx := r.ctx
	ctx.run = h
	node_rewind(r.root, ctx)
	_run_end(h.index, false)
}

// What a live run is doing, for tools that list runs.
Run_Info :: struct {
	handle:        Handle,
	root:          typeid, // the root node's type
	subject:       engine.Transform_Handle,
	bound:         bool,
	owner:         engine.Transform_Handle,
	clock:         time.Clock,
	paused:        bool,
	waiting:       bool, // held by wait_for
	done:          bool, // a held run whose tree is done
	time_scale:    f32,
	elapsed:       f32,
	length:        f32,
	length_known:  bool,
}

// Every live run, in slot order.
run_infos :: proc(allocator := context.temp_allocator) -> []Run_Info {
	out := make([dynamic]Run_Info, 0, len(_runs), allocator)
	for &r, i in _runs {
		if !r.alive do continue
		root: typeid
		if int(r.root.kind) < len(_descs) do root = _descs[r.root.kind].tid
		append(&out, Run_Info {
			handle       = Handle{index = u32(i), generation = r.generation},
			root         = root,
			subject      = r.ctx.subject,
			bound        = r.bound,
			owner        = r.owner,
			clock        = r.clock,
			paused       = r.paused,
			waiting      = r.waits_on != {} && is_alive(r.waits_on),
			done         = r.done,
			time_scale   = r.time_scale,
			elapsed      = r.elapsed,
			length       = r.length,
			length_known = r.length_known,
		})
	}
	return out[:]
}

// Hands the run over to an object: the run stops when the object is
// destroyed, and does not advance while the object is inactive.
bind :: proc(h: Handle, owner: engine.Transform_Handle) {
	if r := _run_ptr(h); r != nil {
		r.bound = true
		r.owner = owner
	}
}

// Holds this run until `other` has ended: finished, completed or stopped.
// It is how a new run waits for the one already playing.
wait_for :: proc(h: Handle, other: Handle) {
	if r := _run_ptr(h); r != nil do r.waits_on = other
}

// Stops every run whose subject or bound object is `target`.
stop_on :: proc(target: engine.Transform_Handle) {
	for i in 0 ..< len(_runs) {
		if _run_targets(&_runs[i], target) do stop(_handle_at(i))
	}
}

// Completes every run whose subject or bound object is `target`.
complete_on :: proc(target: engine.Transform_Handle) {
	for i in 0 ..< len(_runs) {
		if _run_targets(&_runs[i], target) do complete(_handle_at(i))
	}
}

// Stops every run.
stop_all :: proc() {
	for i in 0 ..< len(_runs) {
		if _runs[i].alive do stop(_handle_at(i))
	}
}

// Runs alive now.
run_count :: proc() -> int {
	n := 0
	for &r in _runs do if r.alive do n += 1
	return n
}

@(private)
_run_targets :: proc(r: ^_Run, target: engine.Transform_Handle) -> bool {
	return r.alive && (r.ctx.subject == target || (r.bound && r.owner == target))
}

@(private)
_handle_at :: proc(i: int) -> Handle {
	return Handle{index = u32(i), generation = _runs[i].generation}
}

// Frees the slot and the tree, then reports completion. The slot is free
// before the callback runs, so the callback may start a run.
@(private)
_run_end :: proc(index: u32, completed: bool) {
	context.allocator = runtime.default_allocator()
	r := &_runs[index]
	root, on_complete, user := r.root, r.on_complete, r.user
	r^ = _Run{generation = r.generation + 1}
	append(&_free_runs, index)
	node_destroy(root)
	if completed && on_complete != nil do on_complete(user)
}

// --- Ticking --------------------------------------------------------------------------

// The runs on per-frame clocks, each by its clock's step.
@(update={order=1})
tween_update :: proc(dt: f32) {
	_tick_runs(false)
}

// The runs on fixed-tick clocks, each by its clock's step.
@(fixed_update={order=1})
tween_fixed_update :: proc(fixed_dt: f32) {
	_tick_runs(true)
}

// Ticks every run by `dt` seconds, whatever its clock: for tests and for
// stepping tweens by hand.
tick_all :: proc(dt: f32) {
	// Runs started during this pass wait for the next one.
	n := len(_runs)
	for i in 0 ..< n {
		if _runs[i].alive && !_runs[i].paused do _tick_run(u32(i), dt)
	}
}

@(private)
_tick_runs :: proc(fixed: bool) {
	n := len(_runs)
	for i in 0 ..< n {
		r := &_runs[i]
		if !r.alive || r.paused || time.is_fixed(r.clock) != fixed do continue
		_tick_run(u32(i), time.delta_time(r.clock))
	}
}

@(private)
_tick_run :: proc(index: u32, step: f32) {
	r := &_runs[index]
	if r.bound {
		if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(r.owner)) {
			_run_end(index, false)
			return
		}
		if !engine.transform_active_in_hierarchy(r.owner) do return
	}
	if r.done do return
	if r.waits_on != {} {
		if is_alive(r.waits_on) do return
		r.waits_on = {}
	}
	dt := step * r.time_scale
	if dt <= 0 do return
	r.ticking = true
	ctx := r.ctx
	ctx.run = Handle{index = index, generation = r.generation}
	status := tick_node(r.root, dt, ctx)
	// A node may have started a run: the array may have moved.
	r = &_runs[index]
	r.ticking = false
	r.elapsed += dt
	if r.stop_requested {
		_run_end(index, false)
	} else if status == .Done {
		if r.hold {
			r.done = true
		} else {
			_run_end(index, true)
		}
	}
}

// Play ended: nothing a run animates outlives it.
@(phase={key=ExitingPlayMode})
tween_exiting_play_mode :: proc() {
	stop_all()
}

// Frees the prototype library and every run — for owners with real lifetimes
// (tests). The process-lifetime instance never calls this.
destroy_all :: proc() {
	context.allocator = runtime.default_allocator()
	for key, data in _lib {
		delete(key)
		delete(data)
	}
	clear(&_lib)
	for &r in _runs do if r.alive do node_destroy(r.root)
	clear(&_runs)
	clear(&_free_runs)
}
