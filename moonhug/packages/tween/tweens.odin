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
import engine "moonhug:engine"

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
	subject:  engine.Ref `ref:"Transform"`,

	// runtime only fields:
	delay_elapsed: f32 `json:"-"`,
	status:        Status `json:"-"`,
}

TweenContext :: struct {
	subject: engine.Transform_Handle `json:"-"`,
}

tween_has_delay :: proc(base: ^Tween, delta_time: f32) -> bool {
	if base.delay_elapsed < base.delay {
		base.delay_elapsed += delta_time
		return true
	}
	return false
}

// Packages register their node types on this phase (fired by each runnable
// binary next to .SerializationInit). The stock nodes below register through
// the SAME public path at order=0, so foreign registrations may assume the
// runtime is up.
Phase_Extra :: enum {
	TweenNodesInit,
}

@(phase={key=TweenNodesInit, order=0})
register_builtin_nodes :: proc() {
	register_node(Parallel, tick_Parallel)
	register_node(Sequence, tick_Sequence)
	register_node(TweenMoveToLocal, tick_TweenMoveToLocal)
	register_node(TweenRotateToLocal, tick_TweenRotateToLocal)
	register_node(TweenScaleToLocal, tick_TweenScaleToLocal)
}

// The package's own serializer registrations, on the SerializationInit phase.
@(phase={key=SerializationInit, order=1})
tween_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(Authored, _authored_marshal)
	json.register_user_unmarshaler(Authored, _authored_unmarshal)
	engine.register_pointer_type(Authored)
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
