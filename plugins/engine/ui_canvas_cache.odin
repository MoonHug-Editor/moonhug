package engine

// What a canvas draws, kept from one collect to the next.
//
// The collector (canvas_collect_graphics) runs for every view of every
// frame. Most of what it does for a canvas gives the same answer each time:
// resolving every node's rect through the layouts, asking each graphic for
// its quads, running the effects over them. So a canvas keeps that answer,
// and a collect only places the kept quads in its view.
//
// The kept answer is used again while nothing it was made from changed:
// - A fingerprint of the canvas's subtree: every node's transform and the
//   contents of every component on it, strings and lists included. Any
//   field set by game code, an animation, the inspector or an undo changes
//   it, with no call to make.
// - The screen size the canvas is laid out for.
// - canvas_content_changed, for what the fingerprint cannot see: a texture
//   or a font that finished loading or was imported again.
//
// A graphic whose quads depend on something else, the time or a global,
// calls canvas_content_changed when that changes.

import "base:runtime"
import "core:hash/xxhash"
import "core:mem"
import "core:strings"
import "moonhug:libs/prof"

@(private = "file")
_content_epoch: u64 = 1

// Says that something canvases draw from changed outside their components:
// every canvas collects afresh the next time. The texture cache and the text
// plugin call it when a texture or a font loads.
canvas_content_changed :: proc "contextless" () {
	_content_epoch += 1
}

// How many times a canvas was collected afresh, a kept answer not counted:
// for tests and for a look at what a frame costs.
canvas_rebuilds: int

// One node that draws, with where its quads are among the kept ones.
@(private)
_Kept_Node :: struct {
	index: int, // in the rect walk: the draw order
	tH:    Transform_Handle,
	mask:  Transform_Handle, // the nearest UiMask above it, {} for none
	color: [4]f32,           // the graphic's, with the tint and the group's alpha
	xform: matrix[4, 4]f32,
	first, count: int,
}

@(private)
_Canvas_Kept :: struct {
	canvas: Transform_Handle,
	screen: [2]f32,
	print:  u64,
	epoch:  u64,
	built:  bool,
	used:   u64, // _kept_clock at the last use, for dropping the oldest
	nodes:  [dynamic]Node_Rect,
	drawn:  [dynamic]_Kept_Node,
	quads:  [dynamic]Graphic_Quad, // `material` is the one each draws with
	// The quads' own shader values and their names.
	arena:  mem.Dynamic_Arena,
}

// The most canvases kept at once. Past it the one unused the longest goes.
CANVAS_KEPT_MAX :: 64

@(private = "file")
_kept: [dynamic]^_Canvas_Kept
@(private = "file")
_kept_clock: u64

// The kept answer for a canvas at a screen size, made or made again when
// what it came from changed. `root` is the canvas's rect at that size.
@(private)
_canvas_kept :: proc(canvas_tH: Transform_Handle, root: Rect, screen: [2]f32) -> ^_Canvas_Kept {
	_kept_clock += 1
	k: ^_Canvas_Kept
	for e in _kept do if e.canvas == canvas_tH && e.screen == screen {
		k = e
		break
	}
	if k == nil {
		context.allocator = runtime.default_allocator()
		if len(_kept) >= CANVAS_KEPT_MAX {
			oldest := 0
			for e, i in _kept do if e.used < _kept[oldest].used do oldest = i
			_kept_free(_kept[oldest])
			unordered_remove(&_kept, oldest)
		}
		k = new(_Canvas_Kept)
		k.canvas, k.screen = canvas_tH, screen
		k.nodes = make([dynamic]Node_Rect)
		k.drawn = make([dynamic]_Kept_Node)
		k.quads = make([dynamic]Graphic_Quad)
		mem.dynamic_arena_init(&k.arena, runtime.default_allocator(), runtime.default_allocator())
		append(&_kept, k)
	}
	k.used = _kept_clock
	print := canvas_fingerprint(canvas_tH)
	if !k.built || k.print != print || k.epoch != _content_epoch {
		_kept_build(k, root)
		k.print, k.epoch, k.built = print, _content_epoch, true
	}
	return k
}

@(private = "file")
_kept_free :: proc(k: ^_Canvas_Kept) {
	context.allocator = runtime.default_allocator()
	delete(k.nodes)
	delete(k.drawn)
	delete(k.quads)
	mem.dynamic_arena_destroy(&k.arena)
	free(k)
}

// Forgets every kept canvas: tests, and a shutdown.
canvas_kept_clear :: proc() {
	for k in _kept do _kept_free(k)
	delete(_kept)
	_kept = nil
}

// Collects a canvas afresh: its rects, and for each node that draws its
// graphic's quads with the effects run over them.
@(private = "file")
_kept_build :: proc(k: ^_Canvas_Kept, root: Rect) {
	prof.zone()
	canvas_rebuilds += 1
	clear(&k.nodes)
	clear(&k.drawn)
	clear(&k.quads)
	mem.dynamic_arena_free_all(&k.arena)
	keep := mem.dynamic_arena_allocator(&k.arena)
	{
		context.allocator = runtime.default_allocator()
		canvas_resolve_rects(k.canvas, root, &k.nodes)
	}
	any_mask := canvas_clip_any()
	quads := make([dynamic]Graphic_Quad, context.temp_allocator)
	for n, i in k.nodes {
		_, cr := transform_get_comp(n.tH, CanvasRenderer)
		if cr == nil || !cr.enabled do continue
		comp, g, desc, ok := node_graphic(n.tH)
		if !ok do continue
		// The CanvasGroups above it fade it. Fully faded, it draws nothing.
		group_alpha := canvas_group_state(n.tH).alpha
		if group_alpha <= 0 do continue
		clear(&quads)
		desc.populate(comp, n.rect, &quads)
		node_effects(n.tH, n.rect, &quads)
		own_material := asset_key(g.material)
		node := _Kept_Node{
			index = i,
			tH    = n.tH,
			mask  = canvas_clip_nearest(n.tH) if any_mask else Transform_Handle{},
			color = (g.color * cr.tint if cr.tinted else g.color) * {1, 1, 1, group_alpha},
			xform = n.xform,
			first = len(k.quads),
		}
		for q in quads {
			if asset_guid_is_empty(q.texture) do continue
			q := q
			if !asset_guid_is_empty(own_material) do q.material = own_material
			// Its shader values came from frame memory: they move here.
			if len(q.properties) > 0 {
				own := make([]Draw_Property, len(q.properties), keep)
				for p, pi in q.properties do own[pi] = {name = strings.clone(p.name, keep), value = p.value}
				q.properties = own
			}
			append(&k.quads, q)
		}
		node.count = len(k.quads) - node.first
		if node.count > 0 do append(&k.drawn, node)
	}
}

// --- Fingerprint -------------------------------------------------------------------

// A hash of everything under a canvas that its picture can come from: each
// node's place in the tree, its transform, whether it is active, and every
// component on it with its contents. Strings and lists are hashed by what
// they hold, so text typed into the same memory still counts. Nodes under an
// inactive one are left out, as they draw nothing.
canvas_fingerprint :: proc(canvas_tH: Transform_Handle) -> u64 {
	prof.zone()
	w := ctx_world()
	h := u64(0x9E3779B97F4A7C15)
	stack := make([dynamic]Transform_Handle, context.temp_allocator)
	append(&stack, canvas_tH)
	for len(stack) > 0 {
		tH := pop(&stack)
		t := pool_get(&w.transforms, Handle(tH))
		if t == nil do continue
		Node :: struct {
			tH:       Transform_Handle,
			position: [3]f32,
			rotation: [4]f32,
			scale:    [3]f32,
			layer:    u32,
			active:   bool,
			comps:    i32,
			children: i32,
		}
		// Zeroed first: the padding between fields is part of the bytes hashed.
		node: Node
		node.tH, node.position, node.rotation, node.scale = tH, t.position, t.rotation, t.scale
		node.layer, node.active = t.render_layer, t.is_active
		node.comps, node.children = i32(len(t.components)), i32(len(t.children))
		h = _hash_bytes(h, &node, size_of(Node))
		if !t.is_active do continue
		for owned in t.components {
			key := owned.handle.type_key
			c := world_pool_get(w, owned.handle)
			if c == nil do continue
			handle := owned.handle
			h = _hash_bytes(h, &handle, size_of(Handle))
			h = _hash_component(h, c, key)
		}
		#reverse for child in t.children do append(&stack, Transform_Handle(child.handle))
	}
	return h
}

// How to hash one component type: its bytes in runs, with the strings and
// lists among them followed. Made once a type, so a fingerprint does no
// type lookups.
@(private = "file")
_Hash_Op :: struct {
	kind:   enum u8 {Bytes, String, List},
	offset: uintptr,
	size:   int,                // Bytes
	elem:   ^runtime.Type_Info, // List
}

@(private = "file")
_hash_plans: [TypeKey][]_Hash_Op
@(private = "file")
_hash_planned: [TypeKey]bool

@(private = "file")
_hash_component :: proc(h: u64, c: rawptr, key: TypeKey) -> u64 {
	if !_hash_planned[key] {
		_hash_planned[key] = true
		if tid := component_registry[key].tid; tid != nil {
			context.allocator = runtime.default_allocator()
			ops := make([dynamic]_Hash_Op)
			_hash_plan(&ops, type_info_of(tid), 0)
			_hash_plans[key] = ops[:]
		}
	}
	h := h
	for op in _hash_plans[key] {
		at := rawptr(uintptr(c) + op.offset)
		switch op.kind {
		case .Bytes:
			h = _hash_bytes(h, at, op.size)
		case .String:
			s := (cast(^string)at)^
			n := len(s)
			h = _hash_bytes(h, &n, size_of(int))
			h = _hash_bytes(h, raw_data(s), n)
		case .List:
			raw := cast(^runtime.Raw_Dynamic_Array)at // a slice starts the same way
			h = _hash_list(h, raw.data, raw.len, op.elem)
		}
	}
	return h
}

// Adds a type's ops at `offset`. Runs of plain bytes that touch are one op.
@(private = "file")
_hash_plan :: proc(ops: ^[dynamic]_Hash_Op, ti: ^runtime.Type_Info, offset: uintptr) {
	bytes :: proc(ops: ^[dynamic]_Hash_Op, offset: uintptr, size: int) {
		if size <= 0 do return
		if n := len(ops); n > 0 && ops[n - 1].kind == .Bytes && ops[n - 1].offset + uintptr(ops[n - 1].size) >= offset {
			// The padding between two fields joins the run.
			ops[n - 1].size = int(offset - ops[n - 1].offset) + size
			return
		}
		append(ops, _Hash_Op{kind = .Bytes, offset = offset, size = size})
	}
	if _type_flat(ti) {
		bytes(ops, offset, ti.size)
		return
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		_hash_plan(ops, v.base, offset)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) do _hash_plan(ops, v.types[i], offset + v.offsets[i])
	case runtime.Type_Info_String:
		if v.is_cstring {
			bytes(ops, offset, ti.size)
		} else {
			append(ops, _Hash_Op{kind = .String, offset = offset})
		}
	case runtime.Type_Info_Dynamic_Array:
		append(ops, _Hash_Op{kind = .List, offset = offset, elem = v.elem})
	case runtime.Type_Info_Slice:
		append(ops, _Hash_Op{kind = .List, offset = offset, elem = v.elem})
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count do _hash_plan(ops, v.elem, offset + uintptr(i * v.elem_size))
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count do _hash_plan(ops, v.elem, offset + uintptr(i * v.elem_size))
	case:
		bytes(ops, offset, ti.size)
	}
}

@(private = "file")
_hash_bytes :: proc(h: u64, ptr: rawptr, size: int) -> u64 {
	if size <= 0 || ptr == nil do return h * 31 + 1
	return u64(xxhash.XXH3_64_with_seed((cast([^]u8)ptr)[:size], xxhash.xxh_u64(h)))
}

// Whether a value of the type is all in its own bytes: no string, list or
// pointer to follow.
@(private = "file")
_flat: map[typeid]bool

@(private = "file")
_type_flat :: proc(ti: ^runtime.Type_Info) -> bool {
	if known, has := _flat[ti.id]; has do return known
	flat := false
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		flat = _type_flat(v.base)
	case runtime.Type_Info_Integer, runtime.Type_Info_Rune, runtime.Type_Info_Float, runtime.Type_Info_Complex,
	     runtime.Type_Info_Quaternion, runtime.Type_Info_Boolean, runtime.Type_Info_Enum, runtime.Type_Info_Bit_Set,
	     runtime.Type_Info_Matrix, runtime.Type_Info_Bit_Field:
		flat = true
	case runtime.Type_Info_Array:
		flat = _type_flat(v.elem)
	case runtime.Type_Info_Enumerated_Array:
		flat = _type_flat(v.elem)
	case runtime.Type_Info_Struct:
		flat = true
		for i in 0 ..< int(v.field_count) do if !_type_flat(v.types[i]) {
			flat = false
			break
		}
	case runtime.Type_Info_String, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Slice:
		flat = false
	case:
		// A pointer, a map, a proc, a union: hashed by its own bytes.
		flat = true
	}
	context.allocator = runtime.default_allocator()
	if _flat == nil do _flat = make(map[typeid]bool)
	_flat[ti.id] = flat
	return flat
}

@(private = "file")
_hash_value :: proc(h: u64, ptr: rawptr, ti: ^runtime.Type_Info) -> u64 {
	if _type_flat(ti) do return _hash_bytes(h, ptr, ti.size)
	h := h
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return _hash_value(h, ptr, v.base)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			h = _hash_value(h, rawptr(uintptr(ptr) + v.offsets[i]), v.types[i])
		}
		return h
	case runtime.Type_Info_String:
		if v.is_cstring do return _hash_bytes(h, ptr, ti.size)
		s := (cast(^string)ptr)^
		n := len(s)
		h = _hash_bytes(h, &n, size_of(int))
		return _hash_bytes(h, raw_data(s), n)
	case runtime.Type_Info_Dynamic_Array:
		raw := cast(^runtime.Raw_Dynamic_Array)ptr
		return _hash_list(h, raw.data, raw.len, v.elem)
	case runtime.Type_Info_Slice:
		raw := cast(^runtime.Raw_Slice)ptr
		return _hash_list(h, raw.data, raw.len, v.elem)
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count do h = _hash_value(h, rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem)
		return h
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count do h = _hash_value(h, rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem)
		return h
	}
	return _hash_bytes(h, ptr, ti.size)
}

@(private = "file")
_hash_list :: proc(h: u64, data: rawptr, count: int, elem: ^runtime.Type_Info) -> u64 {
	h := h
	n := count
	h = _hash_bytes(h, &n, size_of(int))
	if data == nil || count <= 0 do return h
	if _type_flat(elem) do return _hash_bytes(h, data, count * elem.size)
	for i in 0 ..< count do h = _hash_value(h, rawptr(uintptr(data) + uintptr(i * elem.size)), elem)
	return h
}
