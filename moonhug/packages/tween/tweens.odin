package tween

// MoonHug's tween types and their runner instance, bound to the generic
// Runner in tween.odin. This file and nodes.odin import engine (tweens target
// transforms) -- the Runner file does not, and stays reusable on its own.
// Dispatch keys are TypeKeys cast to int: the generated __tween_ticks_init
// (tween_gen) writes the runner's dense arrays with `int(engine.TypeKey.X)`,
// so the table is exactly as large as the enum and dispatch stays an array
// index.
//
// Nothing here is serialized by key or tag: tween payloads (scene files, the
// runner's prototype library, undo) go through the GUID-keyed union
// marshaler, so tag values and TypeKey ints renumbering across builds cannot
// corrupt persisted data.

import "base:runtime"
import "core:encoding/json"
import "core:reflect"
import engine "moonhug:engine"
import ser "moonhug:engine/serialization"

TweenStatus :: Status

TweenContext :: struct {
	subject: engine.Transform_Handle `json:"-"`,
}

// Hierarchical Task
@(typ_guid={guid="aecaf150-0418-4fed-81a3-708f68ccaa8b"})
Tween :: struct {
	skip:     bool,
	is_await: bool,
	delay:    f32,
	subject:  engine.Ref `ref:"Transform"`,

	// runtime only fields:
	delay_elapsed: f32 `json:"-"`,
	status:        TweenStatus `json:"-"`,
}

tween_base :: proc(task: ^TweenUnion) -> ^Tween {
	return cast(^Tween)task
}

tick_Tween :: proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> TweenStatus {
	return .Done
}

tween_has_delay :: proc(base: ^Tween, delta_time: f32) -> bool {
	if base.delay_elapsed < base.delay {
		base.delay_elapsed += delta_time
		return true
	}
	return false
}

// The package's own serializer registrations, on the SerializationInit phase --
// engine's serialization no longer names this package's types anywhere. The
// order=0 subscriber (register_component_serializers) installs the registries
// first.
@(phase={key=SerializationInit, order=1})
tween_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(TweenUnion, ser.union_marshal)
	json.register_user_unmarshaler(TweenUnion, ser.union_unmarshal)
	engine.register_pointer_type(TweenUnion)
}

// --- The runner instance ----------------------------------------------------

// Sized by the TypeKey enum itself, so a new tween type grows the table with
// no constant to maintain.
@(private)
_tween_runner: Runner(TweenUnion, TweenContext, len(engine.TypeKey))

// The runner's own setup, called FIRST by the generated __tween_ticks_init so
// registration order cannot be gotten wrong by hand.
//
// State is process-global (registered prototypes and running tweens outlive
// any caller frame), so the runner lives on the default allocator -- a
// caller's temp or tracking allocator tears down while entries live on.
tween_runner_setup :: proc() {
	init(&_tween_runner, _tween_key_of, _tween_skip_of, runtime.default_allocator())
}

@(private)
_tween_key_of :: proc(task: ^TweenUnion) -> (int, bool) {
	tid := reflect.union_variant_typeid(task^)
	if tid == nil do return 0, false
	key, ok := engine.get_type_key_by_typeid(tid)
	return int(key), ok
}

@(private)
_tween_skip_of :: proc(task: ^TweenUnion) -> bool {
	return tween_base(task).skip
}

// --- The API the engine and app code call ------------------------------------

tween_init :: proc() {
	__tween_ticks_init()
}

tween_register :: proc(key: string, tween: ^TweenUnion) {
	register(&_tween_runner, key, tween)
}

tween_lib_count :: proc() -> int {
	return lib_count(&_tween_runner)
}

tween_run :: proc {
	tween_run_key,
	tween_run_tween,
}

tween_run_key :: proc(key: string, ctx: TweenContext) -> bool {
	return run_key(&_tween_runner, key, ctx)
}

tween_run_tween :: proc(tween: ^TweenUnion, ctx: TweenContext) -> bool {
	return run_value(&_tween_runner, tween, ctx)
}

tween_free :: proc(task: ^TweenUnion) {
	free_task(&_tween_runner, task)
}

// `ctx` is accepted for call-site compatibility: each running tween carries
// the context it was started with, which is what its ticks receive.
tween_tick_running :: proc(delta_time: f32, ctx: TweenContext) {
	tick_running(&_tween_runner, delta_time)
}

// Composite tweens (Sequence, Parallel) tick their children through this.
_tween_tick_child :: proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> TweenStatus {
	return tick_task(&_tween_runner, task, delta_time, ctx)
}
