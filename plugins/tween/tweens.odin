package tween

// MoonHug's tween surface: the base vocabulary every node embeds, blob
// serialization, and registration of the stock node types. The runtime
// (registry, pools, run list) lives in runtime.odin, leaf nodes in
// leaves.odin, composites in composites.odin.
//
// Nothing here is serialized by table index: authored payloads (scene files,
// the prototype library, undo) are guid-tagged JSON, so registration order
// and pool layout cannot corrupt persisted data.

import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:math/ease"
import "moonhug:libs/time"
import engine "moonhug:packages/engine"

Status :: enum {
	Pending,
	Running,
	Done,
}

TweenStatus :: Status

// Hierarchical Task
@(typ_guid={guid="aecaf150-0418-4fed-81a3-708f68ccaa8b"})
Tween :: struct {
	skip:     bool,
	is_await: bool,
	delay:    f32,
	// The object this node animates. Empty: the subject the run was started
	// with. Set: this object, whatever the code passed.
	subject:  engine.Ref `ref:"Transform"`,
	// On a tree's root: the clock the tree runs on. Off: the clock the code
	// passed when it started the tree.
	own_clock: bool,
	clock:     time.Clock,

	// runtime only fields:
	delay_elapsed: f32 `json:"-"`,
	status:        Status `json:"-"`,
	// The object this node animates when it is not the run's subject: the
	// authored `subject` resolved when the run starts, or the object the code
	// API was called with.
	target:        engine.Transform_Handle `json:"-" inspect:"-"`,
}

// The object a node animates: its own target, or the run's subject.
subject_of :: proc(base: ^Tween, ctx: TweenContext) -> engine.Transform_Handle {
	return base.target if base.target != {} else ctx.subject
}

TweenContext :: struct {
	subject: engine.Transform_Handle `json:"-"`,
	// The run the node ticks in. The runtime fills it.
	run:     Handle `json:"-"`,
}

// How a value node moves between its start and its end over one cycle.
// Saved as a number: new values go at the end.
Ease :: enum u8 {
	Linear,
	Curve, // the node's `curve`, 0..1 on both axes
	Quad_In,
	Quad_Out,
	Quad_In_Out,
	Cubic_In,
	Cubic_Out,
	Cubic_In_Out,
	Quart_In,
	Quart_Out,
	Quart_In_Out,
	Quint_In,
	Quint_Out,
	Quint_In_Out,
	Sine_In,
	Sine_Out,
	Sine_In_Out,
	Circ_In,
	Circ_Out,
	Circ_In_Out,
	Expo_In,
	Expo_Out,
	Expo_In_Out,
	Elastic_In,
	Elastic_Out,
	Elastic_In_Out,
	Back_In,
	Back_Out,
	Back_In_Out,
	Bounce_In,
	Bounce_Out,
	Bounce_In_Out,
}

// What a value node does after its first cycle. Saved as a number: new
// values go at the end.
Cycle_Mode :: enum u8 {
	Restart,     // every cycle goes start to end
	Yoyo,        // every second cycle goes end to start, eased the same way
	Incremental, // every cycle starts where the last one ended and moves by the same amount
	Rewind,      // every second cycle plays the first one backwards
}

// What every value node (register_tween) embeds next to Tween: how it
// eases and how often it repeats. The runtime owns the node's time, so a
// value node only captures its start and applies a factor.
@(typ_guid={guid="5b0e7c62-1f3d-4a58-9c21-7e4d6a0f93b5"})
Tween_Anim :: struct {
	ease:       Ease,
	curve:      engine.Curve,
	// How many times the node plays: 0 and 1 play once, -1 repeats until the
	// run is stopped or completed.
	cycles:     i32,
	cycle_mode: Cycle_Mode,

	// runtime only fields:
	elapsed: f32 `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`,
	// The order the node began in, among all value nodes: rewind undoes them
	// newest first.
	began:   u64 `json:"-" inspect:"-"`,
}

// Frees the curve's keys. A value node's own type_cleanup calls this.
type_cleanup_Tween_Anim :: proc(a: ^Tween_Anim) {
	delete(a.curve.keys)
	a^ = {}
}

@(private = "file")
_EASE_FUNCS := [Ease]ease.Ease {
	.Linear         = .Linear,
	.Curve          = .Linear,
	.Quad_In        = .Quadratic_In,
	.Quad_Out       = .Quadratic_Out,
	.Quad_In_Out    = .Quadratic_In_Out,
	.Cubic_In       = .Cubic_In,
	.Cubic_Out      = .Cubic_Out,
	.Cubic_In_Out   = .Cubic_In_Out,
	.Quart_In       = .Quartic_In,
	.Quart_Out      = .Quartic_Out,
	.Quart_In_Out   = .Quartic_In_Out,
	.Quint_In       = .Quintic_In,
	.Quint_Out      = .Quintic_Out,
	.Quint_In_Out   = .Quintic_In_Out,
	.Sine_In        = .Sine_In,
	.Sine_Out       = .Sine_Out,
	.Sine_In_Out    = .Sine_In_Out,
	.Circ_In        = .Circular_In,
	.Circ_Out       = .Circular_Out,
	.Circ_In_Out    = .Circular_In_Out,
	.Expo_In        = .Exponential_In,
	.Expo_Out       = .Exponential_Out,
	.Expo_In_Out    = .Exponential_In_Out,
	.Elastic_In     = .Elastic_In,
	.Elastic_Out    = .Elastic_Out,
	.Elastic_In_Out = .Elastic_In_Out,
	.Back_In        = .Back_In,
	.Back_Out       = .Back_Out,
	.Back_In_Out    = .Back_In_Out,
	.Bounce_In      = .Bounce_In,
	.Bounce_Out     = .Bounce_Out,
	.Bounce_In_Out  = .Bounce_In_Out,
}

// The eased factor at `t` in 0..1. Back and Elastic leave 0..1 on purpose.
// An empty curve is linear.
ease_eval :: proc(e: Ease, t: f32, curve: ^engine.Curve = nil) -> f32 {
	if e == .Linear do return t
	if e == .Curve {
		if curve == nil || len(curve.keys) == 0 do return t
		return engine.curve_eval(curve, t)
	}
	return ease.ease(_EASE_FUNCS[e], t)
}

// The factor a value node applies at `local` (0..1) of cycle number `cycle`.
anim_factor :: proc(anim: ^Tween_Anim, cycle: int, local: f32) -> f32 {
	switch anim.cycle_mode {
	case .Restart:
		return ease_eval(anim.ease, local, &anim.curve)
	case .Yoyo:
		e := ease_eval(anim.ease, local, &anim.curve)
		return 1 - e if cycle % 2 == 1 else e
	case .Incremental:
		return f32(cycle) + ease_eval(anim.ease, local, &anim.curve)
	case .Rewind:
		return ease_eval(anim.ease, 1 - local if cycle % 2 == 1 else local, &anim.curve)
	}
	return local
}

// The factor a value node rests at after `cycles` full cycles.
anim_end_factor :: proc(anim: ^Tween_Anim, cycles: int) -> f32 {
	switch anim.cycle_mode {
	case .Restart:
		return 1
	case .Incremental:
		return f32(cycles)
	case .Yoyo, .Rewind:
		return 0 if cycles % 2 == 0 else 1
	}
	return 1
}

// True while the node's `delay` runs. complete skips what is left of it.
has_delay :: proc(base: ^Tween, delta_time: f32) -> bool {
	if _completing {
		base.delay_elapsed = base.delay
		return false
	}
	if base.delay_elapsed < base.delay {
		base.delay_elapsed += delta_time
		return true
	}
	return false
}

// Packages register their node types on the SerializationInit phase, which
// every runnable binary and the tests fire: the node registry is what reads
// authored trees back. The stock nodes below register through the SAME
// public path. The registry is up from program start, so registration order
// does not matter.
@(phase={key=SerializationInit, order=1})
register_builtin_nodes :: proc() {
	register_node(Parallel, tick_Parallel, .Longest)
	register_node(Sequence, tick_Sequence, .Sum)
	register_target_nodes()
	register_code_nodes()
	register_tween(TweenMoveToLocal, begin_TweenMoveToLocal, apply_TweenMoveToLocal)
	register_tween(TweenRotateToLocal, begin_TweenRotateToLocal, apply_TweenRotateToLocal)
	register_tween(TweenScaleToLocal, begin_TweenScaleToLocal, apply_TweenScaleToLocal)
}

// The package's own serializer registrations, on the SerializationInit phase.
@(phase={key=SerializationInit, order=1})
tween_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(Authored, _authored_marshal)
	json.register_user_unmarshaler(Authored, _authored_unmarshal)
	// Copy/paste and prefab instantiation remap Local_IDs through typed
	// walks — Authored blobs are opaque to them, so the engine calls back.
	engine.register_ref_remap_hook(typeid_of(Authored), _authored_remap)
}

// An Authored field serializes as its value, verbatim — the scene file shape
// is the nested guid-tagged object tree.
_authored_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	a := cast(^Authored)v.data
	if a.value == nil {
		_, e := io.write_string(w, "null")
		if e != .None do return .Unsupported_Type
		return nil
	}
	bytes, err := json.marshal(a.value, opt^, context.temp_allocator)
	if err != nil do return err
	_, e := io.write(w, bytes)
	if e != .None do return .Unsupported_Type
	return nil
}

_authored_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	// Rules this proc lives by:
	// - parse_value allocates from the PARSER's allocator. The stored value
	//   is a deep clone on the default allocator (authored_destroy's
	//   contract), and the parsed original is destroyed under the parser's.
	// - The destination is never read: unmarshal targets can be freshly
	//   allocated uninitialized memory (dynamic-array slots). Overwriting a
	//   live component leaks the old value — the same semantic every other
	//   heap field has on that path.
	val, perr := json.parse_value(p)
	if perr != nil do return perr
	prev := context.allocator
	defer context.allocator = prev
	// LIFO: the destroy runs before the restore above.
	defer {
		context.allocator = p.allocator
		json.destroy_value(val)
	}

	context.allocator = runtime.default_allocator()
	(cast(^Authored)v.data).value = json.clone_value(val)
	return nil
}
