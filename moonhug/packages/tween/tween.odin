package tween

// Tween scheduling, generic over the tween type. This package owns the
// LIBRARY (named, serialized tween prototypes), the RUNNING list and the
// dispatch -- and knows nothing about what a tween does, what it targets or
// what the union's variants are.
//
//   Runner(U, Ctx, N)
//     U    - the caller's tween union. Every variant embeds the caller's base
//            struct, which this package never sees -- it reaches base facts
//            through the two hooks below.
//     Ctx  - the caller's per-run context, passed through to tick procs
//            untouched.
//     N    - dispatch table size. Dense arrays indexed by the caller's own
//            key (MoonHug passes int(TypeKey.X)), so dispatch is an array
//            index, not a hash.
//
// The caller installs two hooks at init:
//     key_of(task)  - the dispatch key of a task's active variant
//     skip_of(task) - the base `skip` flag, read before running
//
// Registered prototypes are stored as JSON, not values: a prototype is
// instantiated per run by unmarshal, so two runs of "Anim0" never share heap
// (children arrays and the like). Marshaling uses whatever user marshalers
// the process registered for U, so a union round-trips exactly as it does in
// scene files.

import "base:runtime"
import "core:encoding/json"
import "core:strings"

Status :: enum {
	Pending,
	Running,
	Done,
}

// One live run: an instantiated prototype plus the context it runs against,
// linked into the runner's running list.
Running :: struct($U, $Ctx: typeid) {
	data: U,
	ctx:  Ctx,
	next: ^Running(U, Ctx),
	prev: ^Running(U, Ctx),
}

Runner :: struct($U, $Ctx: typeid, $N: int) {
	// Dispatch, indexed by the caller's key. Written directly by the caller's
	// generated registration -- `ticks[int(TypeKey.X)] = tick_X`.
	ticks: [N]proc(task: ^U, delta_time: f32, ctx: Ctx) -> Status,
	frees: [N]proc(task: ^U),

	key_of:  proc(task: ^U) -> (int, bool),
	skip_of: proc(task: ^U) -> bool,

	// Named prototypes as marshaled JSON. The map, its keys and the payloads
	// all live on `allocator`: entries outlive any caller frame, so the caller
	// passes a process-lifetime allocator -- a temp-allocated key dangles
	// after a frame's free_all and lookups silently miss.
	lib: map[string][]byte,

	running: ^Running(U, Ctx),

	allocator: runtime.Allocator,
}

init :: proc(
	r: ^Runner($U, $Ctx, $N),
	key_of: proc(task: ^U) -> (int, bool),
	skip_of: proc(task: ^U) -> bool,
	allocator := context.allocator,
) {
	r.allocator = allocator
	r.key_of = key_of
	r.skip_of = skip_of
	r.lib = make(map[string][]byte, allocator)
}

// Registers a prototype under a name. The tween is serialized HERE -- the
// caller's value is not referenced afterwards.
register :: proc(r: ^Runner($U, $Ctx, $N), key: string, tween: ^U) {
	if key in r.lib do return
	data, err := json.marshal(tween^, {spec = .JSON}, r.allocator)
	if err != nil do return
	// The map owns its key: callers routinely build keys with tprintf.
	r.lib[strings.clone(key, r.allocator)] = data
}

lib_count :: proc(r: ^Runner($U, $Ctx, $N)) -> int {
	return len(r.lib)
}

// Instantiates a registered prototype and starts it.
run_key :: proc(r: ^Runner($U, $Ctx, $N), key: string, ctx: Ctx) -> bool {
	raw, ok := r.lib[key]
	if !ok do return false

	node := new(Running(U, Ctx), r.allocator)
	if err := json.unmarshal(raw, &node.data, .JSON, r.allocator); err != nil {
		free(node, r.allocator)
		return false
	}
	return _run(r, node, ctx)
}

// Starts a caller-built tween. The VALUE is copied in -- ownership of its heap
// (children arrays) moves to the runner, which frees it when the run ends.
run_value :: proc(r: ^Runner($U, $Ctx, $N), tween: ^U, ctx: Ctx) -> bool {
	node := new(Running(U, Ctx), r.allocator)
	node.data = tween^
	return _run(r, node, ctx)
}

@(private)
_run :: proc(r: ^Runner($U, $Ctx, $N), node: ^Running(U, Ctx), ctx: Ctx) -> bool {
	if r.skip_of != nil && r.skip_of(&node.data) {
		free_task(r, &node.data)
		free(node, r.allocator)
		return false
	}
	node.ctx = ctx
	node.next = r.running
	if r.running != nil do r.running.prev = node
	r.running = node
	return true
}

// Dispatches one task to its variant's tick. Composite tweens call this for
// their children.
tick_task :: proc(r: ^Runner($U, $Ctx, $N), task: ^U, delta_time: f32, ctx: Ctx) -> Status {
	if r.key_of == nil do return .Done
	key, ok := r.key_of(task)
	if !ok || key < 0 || key >= N do return .Done
	if r.skip_of != nil && r.skip_of(task) do return .Done
	tick := r.ticks[key]
	if tick == nil do return .Done
	return tick(task, delta_time, ctx)
}

// Ticks every live run, unlinking and freeing the finished ones.
tick_running :: proc(r: ^Runner($U, $Ctx, $N), delta_time: f32) {
	node := r.running
	for node != nil {
		next := node.next
		status := tick_task(r, &node.data, delta_time, node.ctx)
		if status == .Done {
			if node.prev != nil do node.prev.next = node.next
			if node.next != nil do node.next.prev = node.prev
			if r.running == node do r.running = node.next
			free_task(r, &node.data)
			free(node, r.allocator)
		}
		node = next
	}
}

// Frees a task's INTERNALS through its variant's free proc (children arrays
// and the like). The task's own storage belongs to the caller.
free_task :: proc(r: ^Runner($U, $Ctx, $N), task: ^U) {
	if r.key_of == nil do return
	key, ok := r.key_of(task)
	if !ok || key < 0 || key >= N do return
	fp := r.frees[key]
	if fp != nil do fp(task)
}

// Frees everything the runner owns: the prototype library and any still-live
// runs. The engine's process-lifetime instance never calls this -- it exists
// for owners with real lifetimes, tests included.
destroy :: proc(r: ^Runner($U, $Ctx, $N)) {
	for key, data in r.lib {
		delete(key, r.allocator)
		delete(data, r.allocator)
	}
	delete(r.lib)
	node := r.running
	for node != nil {
		next := node.next
		free_task(r, &node.data)
		free(node, r.allocator)
		node = next
	}
	r.running = nil
}
