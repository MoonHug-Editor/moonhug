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
// - LIVE: tween_run instantiates the blob into per-type pools. Nodes hold
//   children as Node_Handle arrays, dispatch is an index into the desc table,
//   and a finished run destroys its tree recursively.
//
// A node type is a struct embedding Tween at offset 0. Composites
// declare `children: [dynamic]tween.Node_Handle` with json:"-" — the field is
// found by reflection at registration, filled at instantiation.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:mem"
import "core:reflect"
import "core:strings"
import core "moonhug:engine/core"

_POOL_MAX :: 256

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

Node_Desc :: struct {
	tid:             typeid,
	pool:            rawptr,
	entry:           core.Pool_Entry,
	tick_raw:        rawptr, // the typed tick proc, cast back by tick_thunk
	tick_thunk:      proc(tick_raw: rawptr, node: rawptr, dt: f32, ctx: TweenContext) -> Status,
	cleanup_raw:     rawptr, // optional typed cleanup (node-owned heap)
	cleanup_thunk:   proc(cleanup_raw: rawptr, node: rawptr),
	children_offset: int, // byte offset of `children: [dynamic]Node_Handle`, -1 = leaf
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

// Registers a tween node type. $T must embed Tween at offset 0.
// `cleanup` frees node-owned heap beyond the children array (which the
// runtime frees itself). Idempotent per type.
register_node :: proc(
	$T: typeid,
	tick: proc(self: ^T, dt: f32, ctx: TweenContext) -> Status,
	cleanup: proc(self: ^T) = nil,
) {
	if T in _desc_by_tid do return
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

	desc := Node_Desc{
		tid             = T,
		pool            = pool,
		entry           = core.pool_make_entry(pool),
		tick_raw        = rawptr(tick),
		tick_thunk      = proc(tick_raw: rawptr, node: rawptr, dt: f32, ctx: TweenContext) -> Status {
			t := transmute(proc(self: ^T, dt: f32, ctx: TweenContext) -> Status)tick_raw
			return t(cast(^T)node, dt, ctx)
		},
		children_offset = children_offset,
	}
	if cleanup != nil {
		desc.cleanup_raw = rawptr(cleanup)
		desc.cleanup_thunk = proc(cleanup_raw: rawptr, node: rawptr) {
			c := transmute(proc(self: ^T))cleanup_raw
			c(cast(^T)node)
		}
	}
	_desc_by_tid[T] = len(_descs)
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
	return desc.tick_thunk(desc.tick_raw, ptr, dt, ctx)
}

// Frees a live tree: children first, then the node's own heap, then the slot.
node_destroy :: proc(h: Node_Handle) {
	ptr, desc := _node_ptr(h)
	if ptr == nil do return
	if desc.children_offset >= 0 {
		kids := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for k in kids^ do node_destroy(k)
		delete(kids^)
		kids^ = nil
	}
	if desc.cleanup_thunk != nil do desc.cleanup_thunk(desc.cleanup_raw, ptr)
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
	out := make([]typeid, len(_descs), allocator)
	for d, i in _descs do out[i] = d.tid
	return out
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

	if kids, kok := authored_children(v); kok && desc.children_offset >= 0 {
		children := cast(^[dynamic]Node_Handle)(uintptr(ptr) + uintptr(desc.children_offset))
		for child_v in kids {
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

// --- The running list + prototype library ---------------------------------------

@(private)
_Running :: struct {
	root: Node_Handle,
	ctx:  TweenContext,
	next: ^_Running,
	prev: ^_Running,
}

@(private) _running: ^_Running

// Named prototypes as marshaled JSON — instantiated fresh per run, so two
// runs of "Anim0" never share nodes. Map, keys and payloads live on the
// default allocator: entries outlive any caller frame, and a temp-allocated
// key dangles after a frame's free_all.
@(private) _lib: map[string][]byte

@(init)
_lib_init :: proc "contextless" () {
	context = runtime.default_context()
	_lib = make(map[string][]byte, runtime.default_allocator())
}

tween_init :: proc() {
	register_builtin_nodes()
}

tween_register :: proc(key: string, a: ^Authored) {
	if key in _lib do return
	context.allocator = runtime.default_allocator()
	data, err := json.marshal(a.value, {spec = .JSON})
	if err != nil do return
	_lib[strings.clone(key)] = data
}

tween_lib_count :: proc() -> int {
	return len(_lib)
}

tween_run :: proc {
	tween_run_key,
	tween_run_authored,
}

tween_run_key :: proc(key: string, ctx: TweenContext) -> bool {
	raw, ok := _lib[key]
	if !ok do return false
	prev := context.allocator
	context.allocator = context.temp_allocator
	val, perr := json.parse(raw, .JSON, true)
	context.allocator = prev
	if perr != nil do return false
	return tween_run_value(val, ctx)
}

tween_run_authored :: proc(a: ^Authored, ctx: TweenContext) -> bool {
	return tween_run_value(a.value, ctx)
}

// Instantiates and starts a tree from its authored value (not consumed).
tween_run_value :: proc(v: json.Value, ctx: TweenContext) -> bool {
	h, ok := _instantiate(v)
	if !ok do return false
	base := node_base(h)
	if base != nil && base.skip {
		node_destroy(h)
		return false
	}
	context.allocator = runtime.default_allocator()
	node := new(_Running)
	node.root = h
	node.ctx = ctx
	node.next = _running
	if _running != nil do _running.prev = node
	_running = node
	return true
}

// Ticks every live run, destroying the finished ones.
tween_tick_running :: proc(dt: f32, ctx: TweenContext) {
	node := _running
	for node != nil {
		next := node.next
		status := tick_node(node.root, dt, node.ctx)
		if status == .Done {
			if node.prev != nil do node.prev.next = node.next
			if node.next != nil do node.next.prev = node.prev
			if _running == node do _running = node.next
			node_destroy(node.root)
			free(node, runtime.default_allocator())
		}
		node = next
	}
}

// Frees the prototype library and any live runs — for owners with real
// lifetimes (tests). The process-lifetime instance never calls this.
tween_destroy_all :: proc() {
	context.allocator = runtime.default_allocator()
	for key, data in _lib {
		delete(key)
		delete(data)
	}
	clear(&_lib)
	node := _running
	for node != nil {
		next := node.next
		node_destroy(node.root)
		free(node)
		node = next
	}
	_running = nil
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
