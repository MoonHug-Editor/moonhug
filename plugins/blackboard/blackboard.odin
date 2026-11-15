package blackboard

// Blackboard: a component that holds named values for slots
// (moonhug/libs/slots), authored in the inspector.
//
//   Enemy          Blackboard:  tint = red,  speed = 2
//   ├── Body       Glow:   color  <- tint
//   └── Legs       Mover:  speed  <- speed
//
// - A slot on an object takes an entry from the nearest Blackboard on the
//   object or above it, then from the ones further up, then from the
//   game-wide dictionary. The plugin installs that lookup as the slots
//   library's scope, so a reader calls slots.scope_of(owner) and needs no
//   import of this package.
// - Entries are authored on the component: a name, a type and a value. The
//   inspector's link button on a slot lists the entries of the slot's type
//   from the blackboards above the object.
// - A slot connects to an entry's id, not its name. The id is given once,
//   when the entry is made, and never changes, so renaming an entry breaks no
//   connection: the name is read where it is shown. A copy of a Blackboard
//   keeps the ids, so the copy's entries answer the same slots. A nearer
//   Blackboard changes an entry for the objects under it with an entry of the
//   same id (entry_override).
// - An entry code fills is keyed by its name (slots.set, slots.declare): a
//   name in code is stable already.
// - Game code changes a value while the game runs with set(object, name,
//   value). It goes on top of the authored entry and is never saved. The
//   authored entries are read again when they change, so an edit shows at
//   once, in edit mode too.

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "moonhug:libs/slots"
import core "moonhug:libs/core"
import engine "moonhug:packages/engine"

// What an entry holds.
Value_Type :: enum u8 {
	Number,  // f32
	Integer, // i32
	Flag,    // bool
	Vector2, // [2]f32
	Vector3, // [3]f32
	Color,   // [4]f32
	Object,  // core.Ref, an object of the scene
	Asset,   // core.PPtr, an asset or a sub-asset
}

// One authored entry: the value is the field its type names. `id` is what
// slots connect to (entry_key), given when the entry is made (entry_id_new).
@(typ_guid={guid = "2f5ee6c0-4990-46a8-9c83-0759d649e16a"})
Blackboard_Entry :: struct {
	id:      u32 `inspect:"-"`,
	name:    string,
	type:    Value_Type,
	number:  f32,
	integer: i32,
	flag:    bool,
	vector2: [2]f32,
	vector3: [3]f32,
	color:   [4]f32,
	object:  core.Ref `ref:"Transform"`,
	asset:   core.PPtr,
}

type_reset_Blackboard_Entry :: proc(e: ^Blackboard_Entry) {
	e.color = {1, 1, 1, 1}
}

type_cleanup_Blackboard_Entry :: proc(e: ^Blackboard_Entry) {
	delete(e.name)
	e^ = {}
}

@(component={menu="Blackboard/Blackboard"})
@(typ_guid={guid = "9da7f7af-b616-4937-af42-8dea0c54aad9"})
Blackboard :: struct {
	using base: engine.CompData `inspect:"-"`,
	entries: [dynamic]Blackboard_Entry `inline:""`,
}

type_cleanup_Blackboard :: proc(b: ^Blackboard) {
	_state_drop(b)
	for &e in b.entries do type_cleanup_Blackboard_Entry(&e)
	delete(b.entries)
	engine.comp_zero(b)
}

// The type of the value an entry of type `t` holds.
value_typeid :: proc(t: Value_Type) -> typeid {
	switch t {
	case .Number:  return f32
	case .Integer: return i32
	case .Flag:    return bool
	case .Vector2: return [2]f32
	case .Vector3: return [3]f32
	case .Color:   return [4]f32
	case .Object:  return core.Ref
	case .Asset:   return core.PPtr
	}
	return nil
}

// A new entry id: random, never 0, which means "not given yet".
entry_id_new :: proc() -> u32 {
	for {
		if id := rand.uint32(); id != 0 do return id
	}
}

// The slot that connects to entry `e`: its id. An entry without one yet is
// keyed by its name, as an entry code fills is.
entry_key :: proc(e: ^Blackboard_Entry) -> slots.Slot {
	if e.id == 0 do return slots.entry(e.name)
	return slots.entry(fmt.tprintf("#%08x", e.id))
}

// Adds an entry named `name` to `b` with a new id, and returns it. The
// caller sets its type and value. The pointer holds until the list changes.
entry_add :: proc(b: ^Blackboard, name: string) -> ^Blackboard_Entry {
	append(&b.entries, Blackboard_Entry{id = entry_id_new(), name = strings.clone(name), color = {1, 1, 1, 1}})
	return &b.entries[len(b.entries) - 1]
}

// Adds to `b` an entry that stands in for `from`, an entry of a Blackboard
// above it: the same id, so the slots under `b` connected to `from` take this
// one, starting from `from`'s name, type and value.
entry_override :: proc(b: ^Blackboard, from: ^Blackboard_Entry) -> ^Blackboard_Entry {
	e := from^
	e.name = strings.clone(from.name)
	append(&b.entries, e)
	return &b.entries[len(b.entries) - 1]
}

// The entries of the Blackboards above `b`'s object that `b` has no entry
// for, nearest first: what entry_override can stand in for. Temp-allocated.
entries_above :: proc(b: ^Blackboard) -> []^Blackboard_Entry {
	out := make([dynamic]^Blackboard_Entry, context.temp_allocator)
	w := engine.ctx_world()
	if w == nil do return out[:]
	t := engine.pool_get(&w.transforms, engine.Handle(b.owner))
	if t == nil do return out[:]
	up := nearest(engine.Transform_Handle(t.parent.handle))
	for depth := 0; up != nil && depth < 256; depth += 1 {
		next: for &e in up.entries {
			if e.name == "" do continue
			key := entry_key(&e)
			for &mine in b.entries do if entry_key(&mine) == key do continue next
			for have in out do if entry_key(have) == key do continue next
			append(&out, &e)
		}
		ut := engine.pool_get(&w.transforms, engine.Handle(up.owner))
		if ut == nil do break
		up = nearest(engine.Transform_Handle(ut.parent.handle))
	}
	return out[:]
}

// The slot that connects to the entry named `name` a reader on `object`
// would get: the nearest Blackboard's entry of that name, else the name
// itself, an entry code fills.
key_of :: proc(object: engine.Transform_Handle, name: string) -> slots.Slot {
	w := engine.ctx_world()
	b := nearest(object)
	for depth := 0; w != nil && b != nil && depth < 256; depth += 1 {
		for &e in b.entries do if e.name == name do return entry_key(&e)
		t := engine.pool_get(&w.transforms, engine.Handle(b.owner))
		if t == nil do break
		b = nearest(engine.Transform_Handle(t.parent.handle))
	}
	return slots.entry(name)
}

// Sets the entry named `name` to `value` on the nearest Blackboard on
// `object` or above it, for as long as the component lives. It goes on top
// of the authored entry and is not saved. False when no Blackboard is there.
set :: proc(object: engine.Transform_Handle, name: string, value: $T) -> bool {
	b := nearest(object)
	if b == nil do return false
	slots.put(&_state_of(b).written, key_of(object, name), value)
	return true
}

// Takes back what set put on the entry named `name`: readers get the
// authored entry again. False when no Blackboard is on `object` or above it.
unset :: proc(object: engine.Transform_Handle, name: string) -> bool {
	b := nearest(object)
	if b == nil do return false
	st := _state_of(b)
	if st.written.entries != nil do delete_key(&st.written.entries, key_of(object, name))
	return true
}

// The nearest Blackboard on `object` or above it, nil for none.
nearest :: proc(object: engine.Transform_Handle) -> ^Blackboard {
	w := engine.ctx_world()
	if w == nil do return nil
	at := object
	for depth := 0; depth < 256; depth += 1 {
		t := engine.pool_get(&w.transforms, engine.Handle(at))
		if t == nil do return nil
		if _, b := get_comp(at, Blackboard); b != nil do return b
		at = engine.Transform_Handle(t.parent.handle)
	}
	return nil
}

// A Blackboard's dictionaries. `written` is what set put, looked in first,
// then `authored`, the component's entries, then the next Blackboard up.
@(private)
_State :: struct {
	written:  slots.Dict,
	authored: slots.Dict,
	stamp:    u64, // the entries `authored` was made from
	local_id: engine.Local_ID, // the component the state was made for
}

// By component address: components live in pools and do not move. On the
// default allocator, since they outlive frames.
@(private) _states:      map[rawptr]^_State
@(private) _states_lock: sync.Mutex

@(init)
_blackboard_init :: proc "contextless" () {
	context = runtime.default_context()
	_states = make(map[rawptr]^_State, runtime.default_allocator())
	slots.scope_install({dict_of = _dict_of, entries_of = _entries_of, origin_of = _origin_of})
}

@(private)
_state_of :: proc(b: ^Blackboard) -> ^_State {
	sync.guard(&_states_lock)
	st, has := _states[b]
	// The address was another component's before: nothing of it stays.
	if has && st.local_id != b.local_id {
		slots.destroy(&st.written)
		slots.destroy(&st.authored)
		st^ = {local_id = b.local_id}
	}
	if !has {
		st = new(_State, runtime.default_allocator())
		st.local_id = b.local_id
		_states[b] = st
	}
	return st
}

@(private)
_state_drop :: proc(b: ^Blackboard) {
	sync.guard(&_states_lock)
	st, has := _states[b]
	if !has do return
	slots.destroy(&st.written)
	slots.destroy(&st.authored)
	free(st, runtime.default_allocator())
	delete_key(&_states, b)
}

// The entries as one number: `authored` is made again when it changes.
@(private)
_stamp :: proc(b: ^Blackboard) -> u64 {
	mix :: proc(h: u64, bytes: []u8) -> u64 {
		h := h
		for x in bytes do h = (h ~ u64(x)) * 0x100000001b3
		return h
	}
	h: u64 = 0xcbf29ce484222325
	for &e in b.entries {
		id := e.id
		h = mix(h, ([^]u8)(&id)[:size_of(id)])
		h = mix(h, transmute([]u8)e.name)
		h = mix(h, {0xff, u8(e.type)})
		ptr, size := _value_bytes(&e)
		h = mix(h, ([^]u8)(ptr)[:size])
	}
	return h
}

@(private)
_value_bytes :: proc(e: ^Blackboard_Entry) -> (rawptr, int) {
	switch e.type {
	case .Number:  return &e.number, size_of(e.number)
	case .Integer: return &e.integer, size_of(e.integer)
	case .Flag:    return &e.flag, size_of(e.flag)
	case .Vector2: return &e.vector2, size_of(e.vector2)
	case .Vector3: return &e.vector3, size_of(e.vector3)
	case .Color:   return &e.color, size_of(e.color)
	case .Object:  return &e.object, size_of(e.object)
	case .Asset:   return &e.asset, size_of(e.asset)
	}
	return nil, 0
}

// The Blackboard's dictionary, its chain set for where the component is now.
@(private)
_dict :: proc(b: ^Blackboard) -> ^slots.Dict {
	st := _state_of(b)
	if stamp := _stamp(b); stamp != st.stamp || st.authored.entries == nil {
		st.stamp = stamp
		slots.destroy(&st.authored)
		for &e in b.entries {
			key := entry_key(&e)
			// The first entry of a key is the one: a later one is a mistake
			// the inspector shows.
			if key == slots.INLINE || key in st.authored.entries do continue
			switch e.type {
			case .Number:  slots.put(&st.authored, key, e.number)
			case .Integer: slots.put(&st.authored, key, e.integer)
			case .Flag:    slots.put(&st.authored, key, e.flag)
			case .Vector2: slots.put(&st.authored, key, e.vector2)
			case .Vector3: slots.put(&st.authored, key, e.vector3)
			case .Color:   slots.put(&st.authored, key, e.color)
			case .Object:  slots.put(&st.authored, key, e.object)
			case .Asset:   slots.put(&st.authored, key, e.asset)
			}
		}
	}
	st.written.parent = &st.authored
	// The next Blackboard up, or the game-wide dictionary.
	st.authored.parent = slots.global()
	if w := engine.ctx_world(); w != nil {
		if t := engine.pool_get(&w.transforms, engine.Handle(b.owner)); t != nil {
			if up := nearest(engine.Transform_Handle(t.parent.handle)); up != nil do st.authored.parent = _dict(up)
		}
	}
	return &st.written
}

// The slots library's scope (slots.scope_install).
@(private)
_dict_of :: proc(owner: core.Transform_Handle) -> ^slots.Dict {
	b := nearest(owner)
	if b == nil do return nil
	return _dict(b)
}

@(private)
_entries_of :: proc(owner: core.Transform_Handle, T: typeid) -> []slots.Scope_Entry {
	out := make([dynamic]slots.Scope_Entry, context.temp_allocator)
	w := engine.ctx_world()
	if w == nil do return out[:]
	b := nearest(owner)
	for depth := 0; b != nil && depth < 256; depth += 1 {
		t := engine.pool_get(&w.transforms, engine.Handle(b.owner))
		if t == nil do break
		next: for &e in b.entries {
			if e.name == "" || value_typeid(e.type) != T do continue
			key := entry_key(&e)
			// A nearer Blackboard's entry of the key is the one a slot gets.
			for have in out do if have.slot == key do continue next
			append(&out, slots.Scope_Entry{slot = key, name = e.name, from = t.name})
		}
		b = nearest(engine.Transform_Handle(t.parent.handle))
	}
	return out[:]
}

@(private)
_origin_of :: proc(owner: core.Transform_Handle, slot: slots.Slot) -> (slots.Origin, bool) {
	w := engine.ctx_world()
	b := nearest(owner)
	for depth := 0; w != nil && b != nil && depth < 256; depth += 1 {
		t := engine.pool_get(&w.transforms, engine.Handle(b.owner))
		if t == nil do break
		for &e in b.entries do if entry_key(&e) == slot do return {name = e.name, from = t.name, holder = b.owner}, true
		b = nearest(engine.Transform_Handle(t.parent.handle))
	}
	return {}, false
}
