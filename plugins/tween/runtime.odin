package tween

// Handle-based tween runtime. Node types register a Node_Desc at runtime,
// so ANY package adds tween nodes without codegen and without import
// restrictions (node packages may import tween itself).
//
// Two representations, one per concern:
// - AUTHORED: a tween tree is one guid-tagged json.Value (Authored). It lives
//   in component fields, so component marshal, undo, prefab overrides and
//   copy/paste treat it as a plain value. Children nest inside the parent's
//   "children" array — the tree is self-contained data.
// - LIVE: run (runs.odin) instantiates the blob into per-type pools.
//   Nodes hold children as Node_Handle arrays, dispatch is an index into the
//   desc table, and a finished run destroys its tree recursively.
//
// A node type is a struct embedding Tween at offset 0. Composites
// declare `children: [dynamic]tween.Node_Handle` with json:"-" — the field is
// found by reflection at registration, filled at instantiation.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import core "moonhug:libs/core"
import engine "moonhug:packages/engine"
import log "moonhug:libs/log"

// Live nodes of one type at a time. A full pool panics.
_POOL_MAX :: #config(TWEEN_POOL_MAX, 1024)

// index+generation into the kind's pool. kind = index into the desc table.
Node_Handle :: struct {
	index:      u32,
	generation: u16,
	kind:       u16,
}

NIL_NODE :: Node_Handle{kind = max(u16)}

// One authored tween tree: a guid-tagged json.Value, children nested inside.
// Component fields hold this. The value is owned — authored_destroy frees it.
Authored :: struct {
	value: json.Value,
}

// How long a node that ticks itself is (node_length, progress).
Length_Rule :: enum u8 {
	Unknown, // cannot be told: it waits for something
	Instant, // its delay and nothing more
	Sum,     // its children run one after another
	Longest, // its children run together
}

Node_Desc :: struct {
	tid:             typeid,
	key:             core.TypeKey,
	pool:            rawptr,
	entry:           core.Pool_Entry,
	tick_raw:        rawptr, // the typed tick proc, cast back by tick_thunk
	tick_thunk:      proc(tick_raw: rawptr, node: rawptr, dt: f32, ctx: TweenContext) -> Status,
	children_offset: int, // byte offset of `children: [dynamic]Node_Handle`, -1 = leaf
	length_rule:     Length_Rule,
	// Made from code only: it holds procs, so it is not authored and no type
	// picker lists it (registered_node_types).
	code_only:       bool,

	// A value node (register_tween). -1 offsets = a plain node.
	anim_offset:     int, // byte offset of the embedded Tween_Anim
	duration_offset: int, // byte offset of `duration: f32`
	begin_raw:       rawptr,
	begin_thunk:     proc(begin_raw: rawptr, node: rawptr, ctx: TweenContext) -> bool,
	apply_raw:       rawptr,
	apply_thunk:     proc(apply_raw: rawptr, node: rawptr, t: f32, ctx: TweenContext),
}

_descs:       [dynamic]Node_Desc
_desc_by_tid: map[typeid]int

@(init)
_registry_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	_descs = make([dynamic]Node_Desc, alloc)
	_desc_by_tid = make(map[typeid]int, alloc)
}

// Registers a node type that ticks itself: a composite, or a step with its
// own idea of time. $T must embed Tween at offset 0 and carry @(typ_guid). A
// node that owns heap beyond the children array (which the runtime frees
// itself) declares type_cleanup_T next to itself
// (plugins/engine/docs/Components.md, "Lifecycle procs"). `length_rule` says
// how long the node is, which gives its runs a progress. `code_only` marks a
// node that holds procs and is made from code. Idempotent per type.
register_node :: proc(
	$T: typeid,
	tick: proc(self: ^T, dt: f32, ctx: TweenContext) -> Status,
	length_rule := Length_Rule.Unknown,
	code_only := false,
) {
	if T in _desc_by_tid do return
	desc := _desc_make(T)
	desc.length_rule = length_rule
	desc.code_only = code_only
	desc.tick_raw = rawptr(tick)
	desc.tick_thunk = proc(tick_raw: rawptr, node: rawptr, dt: f32, ctx: TweenContext) -> Status {
		t := cast(proc(self: ^T, dt: f32, ctx: TweenContext) -> Status)tick_raw
		return t(cast(^T)node, dt, ctx)
	}
	_desc_add(T, desc)
}

// Registers a value node: one that moves a value from where it is to an
// authored end over `duration` seconds. $T embeds Tween at offset 0 and
// Tween_Anim, has a `duration: f32` field and carries @(typ_guid).
//
// - `begin` runs once when the node starts. It captures the start value and
//   returns false when the target is gone, which ends the node.
// - `apply` writes the value at factor `t`: 0 is the start, 1 is the end.
//   `t` leaves 0..1 with some eases and cycle modes, so apply does not clamp.
// - The runtime owns the rest: delay, time, easing and cycles.
register_tween :: proc(
	$T: typeid,
	begin: proc(self: ^T, ctx: TweenContext) -> bool,
	apply: proc(self: ^T, t: f32, ctx: TweenContext),
	code_only := false,
) {
	if T in _desc_by_tid do return
	desc := _desc_make(T)
	desc.code_only = code_only
	for f in reflect.struct_fields_zipped(T) {
		if f.type.id == typeid_of(Tween_Anim) do desc.anim_offset = int(f.offset)
		if f.name == "duration" && f.type.id == typeid_of(f32) do desc.duration_offset = int(f.offset)
	}
	fmt.assertf(desc.anim_offset >= 0, "tween.register_tween: %v must embed tween.Tween_Anim", typeid_of(T))
	fmt.assertf(desc.duration_offset >= 0, "tween.register_tween: %v needs a `duration: f32` field", typeid_of(T))
	desc.begin_raw = rawptr(begin)
	desc.begin_thunk = proc(begin_raw: rawptr, node: rawptr, ctx: TweenContext) -> bool {
		b := cast(proc(self: ^T, ctx: TweenContext) -> bool)begin_raw
		return b(cast(^T)node, ctx)
	}
	desc.apply_raw = rawptr(apply)
	desc.apply_thunk = proc(apply_raw: rawptr, node: rawptr, t: f32, ctx: TweenContext) {
		a := cast(proc(self: ^T, t: f32, ctx: TweenContext))apply_raw
		a(cast(^T)node, t, ctx)
	}
	_desc_add(T, desc)
}

@(private)
_desc_make :: proc($T: typeid) -> Node_Desc {
	key, kok := core.get_type_key_by_typeid(T)
	fmt.assertf(kok, "tween: %v needs @(typ_guid) (registered before this call)", typeid_of(T))
	// Process-global registry and pools: never on a caller's scoped allocator.
	context.allocator = runtime.default_allocator()

	pool := new(core.Pool(T, _POOL_MAX))
	core.pool_init(pool)

	children_offset := -1
	for f in reflect.struct_fields_zipped(T) {
		if f.type.id == typeid_of([dynamic]Node_Handle) {
			children_offset = int(f.offset)
			break
		}
	}
	return Node_Desc{
		tid             = T,
		key             = key,
		pool            = pool,
		entry           = core.pool_make_entry(pool),
		children_offset = children_offset,
		anim_offset     = -1,
		duration_offset = -1,
	}
}

@(private)
_desc_add :: proc(tid: typeid, desc: Node_Desc) {
	context.allocator = runtime.default_allocator()
	_desc_by_tid[tid] = len(_descs)
	append(&_descs, desc)
}

@(private)
_core_handle :: proc(h: Node_Handle) -> core.Handle {
	return core.Handle{index = h.index, generation = h.generation, type_key = core.INVALID_TYPE_KEY}
}

@(private)
_node_ptr :: proc(h: Node_Handle) -> (ptr: rawptr, desc: ^Node_Desc) {
	if int(h.kind) >= len(_descs) do return nil, nil
	d := &_descs[h.kind]
	p := d.entry.get_fn(d.pool, _core_handle(h))
	if p == nil do return nil, nil
	return p, d
}

// The embedded base of a live node — nil when the handle is dead.
node_base :: proc(h: Node_Handle) -> ^Tween {
	ptr, _ := _node_ptr(h)
	return cast(^Tween)ptr
}

node_children :: proc(h: Node_Handle) -> ^[dynamic]Node_Handle {
	ptr, desc := _node_ptr(h)
	if ptr == nil || desc.children_offset < 0 do return nil
	return cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
}

// Dispatches one live node to its type's tick. Composites call this for
// their children.
tick_node :: proc(h: Node_Handle, dt: f32, ctx: TweenContext) -> Status {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return .Done
	base := cast(^Tween)ptr
	if base.skip do return .Done
	if desc.anim_offset >= 0 do return _tick_value_node(ptr, desc, dt, ctx)
	return desc.tick_thunk(desc.tick_raw, ptr, dt, ctx)
}

// One step of a value node: delay, then begin once, then the factor for the
// node's time. A node whose object is destroyed ends. Time left over when the
// node ends is dropped.
@(private)
_tick_value_node :: proc(ptr: rawptr, desc: ^Node_Desc, dt: f32, ctx: TweenContext) -> Status {
	base := cast(^Tween)ptr
	anim := cast(^Tween_Anim)(uintptr(ptr) + uintptr(desc.anim_offset))
	if has_delay(base, dt) do return .Running
	if !anim.started {
		if !desc.begin_thunk(desc.begin_raw, ptr, ctx) do return .Done
		anim.started = true
	}
	// The object went away under the node: nothing is left to animate.
	if target := subject_of(base, ctx); target != {} && !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(target)) {
		return .Done
	}
	duration := (cast(^f32)(uintptr(ptr) + uintptr(desc.duration_offset)))^
	cycles := int(anim.cycles)
	if cycles == 0 do cycles = 1
	if duration <= 0 {
		desc.apply_thunk(desc.apply_raw, ptr, anim_end_factor(anim, max(cycles, 1)), ctx)
		return .Done
	}
	// complete ends an endless node at the end of the cycle it is in.
	if cycles < 0 && _completing do cycles = int(anim.elapsed / duration) + 1
	anim.elapsed += dt
	cycle := int(anim.elapsed / duration)
	if cycles > 0 && cycle >= cycles {
		desc.apply_thunk(desc.apply_raw, ptr, anim_end_factor(anim, cycles), ctx)
		return .Done
	}
	local := anim.elapsed / duration - f32(cycle)
	desc.apply_thunk(desc.apply_raw, ptr, anim_factor(anim, cycle, local), ctx)
	return .Running
}

// Seconds a live tree takes from start to end, `ok` false when it cannot be
// told: an endless node, or a node that ticks itself and has no children.
node_length :: proc(h: Node_Handle) -> (seconds: f32, ok: bool) {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return 0, true
	base := cast(^Tween)ptr
	if base.skip do return 0, true
	if desc.anim_offset >= 0 {
		anim := cast(^Tween_Anim)(uintptr(ptr) + uintptr(desc.anim_offset))
		if anim.cycles < 0 do return 0, false
		duration := (cast(^f32)(uintptr(ptr) + uintptr(desc.duration_offset)))^
		return base.delay + max(duration, 0) * f32(max(anim.cycles, 1)), true
	}
	switch desc.length_rule {
	case .Unknown:
		return 0, false
	case .Instant:
		return base.delay, true
	case .Sum, .Longest:
		if desc.children_offset < 0 do return base.delay, true
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		total: f32
		for k in children^ {
			child := node_length(k) or_return
			total = total + child if desc.length_rule == .Sum else max(total, child)
		}
		return base.delay + total, true
	}
	return 0, false
}

// Frees a live tree: children first, then the node's own heap, then the slot.
node_destroy :: proc(h: Node_Handle) {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return
	if desc.children_offset >= 0 {
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for k in children^ do node_destroy(k)
		delete(children^)
		children^ = nil
	}
	core.type_cleanup(desc.key, ptr)
	desc.entry.destroy_fn(desc.pool, _core_handle(h))
}

// --- Authored blobs -----------------------------------------------------------

// Builds an authored node from a typed value. The value is marshaled HERE —
// runtime fields and children arrays carry json:"-" and stay out. Children
// ownership MOVES into the result.
authored :: proc(node: any, children: []Authored = {}) -> Authored {
	context.allocator = runtime.default_allocator()
	bytes, merr := json.marshal(node, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return {}
	val, perr := json.parse(bytes, .JSON, true)
	if perr != nil do return {}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		json.destroy_value(val)
		return {}
	}
	guid := core.get_guid_by_typeid(node.id)
	obj[strings.clone("__type_guid")] = json.String(strings.clone(uuid.to_string(guid, context.temp_allocator)))
	if len(children) > 0 {
		arr: json.Array
		for c in children do append(&arr, c.value)
		obj[strings.clone("children")] = arr
	}
	return Authored{value = obj}
}

// Authored values live on the DEFAULT allocator, always: the builder, the
// unmarshaler and the editor's splice all allocate there, so ownership never
// depends on who happened to load the component (a scene load under a
// scoped allocator would otherwise make this a bad free).
authored_destroy :: proc(a: ^Authored) {
	if a.value != nil {
		context.allocator = runtime.default_allocator()
		json.destroy_value(a.value)
		a.value = nil
	}
}

// The node type of an authored node, resolved through its guid tag.
authored_typeid :: proc(v: json.Value) -> (tid: typeid, ok: bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil, false
	gs, has := obj["__type_guid"].(json.String)
	if !has do return nil, false
	guid, gerr := uuid.read(string(gs))
	if gerr != nil do return nil, false
	t, found := core.guid_to_type[guid]
	return t, found
}

authored_children :: proc(v: json.Value) -> (children: json.Array, ok: bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil, false
	arr, has := obj["children"].(json.Array)
	return arr, has
}

// Registered node types, in registration order. Temp-allocated by default —
// the editor's type picker enumerates these.
registered_node_types :: proc(allocator := context.temp_allocator) -> []typeid {
	out := make([dynamic]typeid, 0, len(_descs), allocator)
	for d in _descs do if !d.code_only do append(&out, d.tid)
	return out[:]
}

// A fresh live node of a registered type, all fields zero: how code builds a
// tree without an authored value (code.odin). The caller fills it and hands
// it to a run or to a parent's children.
node_new :: proc($T: typeid) -> (h: Node_Handle, node: ^T) {
	idx, has := _desc_by_tid[T]
	fmt.assertf(has, "tween.node_new: %v is not registered (tween_init)", typeid_of(T))
	desc := &_descs[idx]
	ch, ptr := desc.entry.create_fn(desc.pool)
	return Node_Handle{index = ch.index, generation = ch.generation, kind = u16(idx)}, cast(^T)ptr
}

// Turns every node's authored `subject` into its target: the object the
// node animates in place of the run's subject. `scene` is where the
// references are looked up. False when a set subject names no object there:
// the tree would animate the wrong thing, so it does not run.
node_resolve_subjects :: proc(h: Node_Handle, scene: ^engine.Scene) -> bool {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return true
	base := cast(^Tween)ptr
	if base.subject.pptr != {} {
		target, found := engine.scene_ref_resolve_transform(scene, base.subject)
		if !found {
			log.errorf("tween: a %v node's subject (local id %d) names no object in the scene of the run's subject, the tree does not run", desc.tid, base.subject.pptr.local_id)
			return false
		}
		base.target = target
	}
	if desc.children_offset >= 0 {
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for k in children^ do node_resolve_subjects(k, scene) or_return
	}
	return true
}

// Gives every node of a live tree that has no target of its own this one
// (subject_of). A tree that joins another run keeps the subject it was
// started with this way.
node_set_default_target :: proc(h: Node_Handle, target: engine.Transform_Handle) {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return
	base := cast(^Tween)ptr
	if base.target == {} do base.target = target
	if desc.children_offset >= 0 {
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for k in children^ do node_set_default_target(k, target)
	}
}

// Whether a registered node type carries children (a composite).
node_type_has_children :: proc(tid: typeid) -> bool {
	idx, has := _desc_by_tid[tid]
	return has && _descs[idx].children_offset >= 0
}

// A fresh authored node of a registered type, with the type's zero values.
authored_make :: proc(tid: typeid) -> (a: Authored, ok: bool) {
	if tid not_in _desc_by_tid do return {}, false
	ti := type_info_of(tid)
	instance, aerr := mem.alloc(ti.size, ti.align, context.temp_allocator)
	if aerr != nil do return {}, false
	return authored(any{instance, tid}), true
}

// Appends a child to a composite node's blob. Ownership of `child` MOVES in.
// Fails (child untouched) when the parent's type is unknown or a leaf.
//
// Mutators take ^json.Value: map inserts and deletes can rehash, and the
// changed map header must land back in the caller's storage — mutating
// through a copied header silently corrupts the blob.
authored_add_child :: proc(parent: ^json.Value, child: Authored) -> bool {
	ptid, tok := authored_typeid(parent^)
	if !tok || !node_type_has_children(ptid) do return false
	m, is_obj := parent^.(json.Object)
	if !is_obj || child.value == nil do return false

	context.allocator = runtime.default_allocator()
	defer parent^ = m
	arr, has := m["children"].(json.Array)
	if !has do arr = make(json.Array)
	append(&arr, child.value)
	if has {
		m["children"] = arr
	} else {
		m[strings.clone("children")] = arr
	}
	return true
}

// Retypes a node in place: every field resets to the new type's zero value.
// Children survive when the new type is a composite and are freed when it is
// a leaf — a subtree is worth more than field values.
//
// The node keeps its identity (same json.Object), so tree position and
// selection paths are unaffected.
authored_retype :: proc(v: ^json.Value, tid: typeid) -> bool {
	fresh, ok := authored_make(tid)
	if !ok do return false
	m, is_obj := v^.(json.Object)
	fobj, fresh_is_obj := fresh.value.(json.Object)
	if !is_obj || !fresh_is_obj {
		authored_destroy(&fresh)
		return false
	}

	context.allocator = runtime.default_allocator()
	// Deletes and inserts can rehash — the header must land back in the
	// caller's storage.
	defer v^ = m
	keep_children := node_type_has_children(tid)

	// Mutating a map while iterating it skips entries — collect keys first.
	// The key strings are freed after removal (json.destroy_value does the
	// same for whole objects).
	old_keys := make([dynamic]string, context.temp_allocator)
	for key in m {
		if keep_children && key == "children" do continue
		append(&old_keys, key)
	}
	for key in old_keys {
		defer delete(key)
		json.destroy_value(m[key])
		delete_key(&m, key)
	}

	// Move the fresh fields in (authored_make already tagged the new guid),
	// then free fresh's keys and map storage by hand — destroy_value would
	// also free the values that just moved.
	defer delete(fobj)
	fresh_keys := make([dynamic]string, context.temp_allocator)
	for key in fobj do append(&fresh_keys, key)
	for key in fresh_keys {
		defer delete(key)
		m[strings.clone(key)] = fobj[key]
	}
	return true
}

// Removes (and frees) a composite node's child by index.
authored_remove_child :: proc(parent: ^json.Value, idx: int) -> bool {
	m, is_obj := parent^.(json.Object)
	if !is_obj do return false
	arr, has := m["children"].(json.Array)
	if !has || idx < 0 || idx >= len(arr) do return false

	context.allocator = runtime.default_allocator()
	defer parent^ = m
	json.destroy_value(arr[idx])
	ordered_remove(&arr, idx)
	m["children"] = arr
	return true
}

// --- Instantiation --------------------------------------------------------------

// Materializes an authored tree into pooled live nodes. Unknown node types
// (package not installed) fail the whole run — a half-instantiated sequence
// would misbehave silently.
_instantiate :: proc(v: json.Value) -> (Node_Handle, bool) {
	context.allocator = runtime.default_allocator()

	tid, tok := authored_typeid(v)
	if !tok do return NIL_NODE, false
	idx, has := _desc_by_tid[tid]
	if !has do return NIL_NODE, false
	desc := &_descs[idx]

	ch, ptr := desc.entry.create_fn(desc.pool)
	h := Node_Handle{index = ch.index, generation = ch.generation, kind = u16(idx)}

	// Overlay the node's fields. `children` and runtime fields are json:"-"
	// on the type, so the object's extra keys are ignored.
	bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	if merr == nil {
		if ptr_tid, pok := core.get_pointer_typeid_by_typeid(tid); pok {
			pp := ptr
			_ = json.unmarshal_any(bytes, any{&pp, ptr_tid})
		}
	}
	core.type_on_validate(desc.key, ptr)

	// Two lists in play: the AUTHORED children (json) being instantiated, and
	// the node's own runtime handle list they land in.
	if authored, kok := authored_children(v); kok && desc.children_offset >= 0 {
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for child_v in authored {
			child_h, cok := _instantiate(child_v)
			if !cok {
				node_destroy(h)
				return NIL_NODE, false
			}
			append(children, child_h)
		}
	}
	return h, true
}

// --- Ref remap inside authored blobs ---------------------------------------------

// Copy/paste and prefab instantiation remap Local_IDs by walking typed
// component memory — an Authored field is opaque to that walk, so the engine
// calls this hook instead (registered at SerializationInit). Any object
// carrying both "local_id" and "guid" keys is a serialized PPtr.
_authored_remap :: proc(ptr: rawptr, remap: ^map[core.Local_ID]core.Local_ID) {
	a := cast(^Authored)ptr
	_value_remap_refs(a.value, remap)
}

_value_remap_refs :: proc(v: json.Value, remap: ^map[core.Local_ID]core.Local_ID) {
	#partial switch obj in v {
	case json.Object:
		// The switch capture is immutable — a local map header shares the
		// same storage, and replacing an existing key never grows the map.
		m := obj
		lid_v, has_lid := m["local_id"]
		_, has_guid := m["guid"]
		if has_lid && has_guid {
			#partial switch lid in lid_v {
			case json.Integer:
				if new_id, ok := remap[core.Local_ID(lid)]; ok {
					m["local_id"] = json.Integer(new_id)
				}
			case json.Float:
				if new_id, ok := remap[core.Local_ID(i64(lid))]; ok {
					m["local_id"] = json.Integer(new_id)
				}
			}
			return
		}
		for _, member in m do _value_remap_refs(member, remap)
	case json.Array:
		for member in obj do _value_remap_refs(member, remap)
	}
}
