package slots

// Slots: a field that takes its value inline, or from a dictionary the game
// fills.
//
//   Mover :: struct {
//       speed:  slots.Slot,                  // what code and the inspector see
//       _speed: f32 `inspect:"-"`,           // the inline value
//   }
//
//   speed := slots.get(m.speed, m._speed, dict)
//
// - A slot is the name of a dictionary entry, or nothing. With nothing, the
//   value is the inline one. With a name, the value is the entry's, and the
//   inline one when no dictionary in the chain has the entry: an edit-mode
//   preview, where no game code runs, shows the inline value.
// - The inline value is the field named as the slot with `_` in front, hidden
//   with `inspect:"-"`. The inspector draws one row under the slot's name:
//   the inline field's own widget, or the entry's name, and a link button
//   that switches between them. The prebuild checks the pair.
// - Code reads through `get`. The underscore says the inline field is not
//   the value: reading it directly ignores a connection.
// - A slot is plain data, a number for the entry's name (`entry`). It saves
//   as the name, an empty string when inline (the serialization library's
//   marshalers), so the number may differ from one run to the next.
//
// A dictionary holds entries by name:
//
//   d: slots.Dict
//   slots.set(&d, "speed", f32(3))                  // a value
//   slots.set_proc(&d, "target", [3]f32, read, me)  // computed on every read
//   d.parent = slots.global()                       // looked in next
//   defer slots.destroy(&d)
//
// - An entry has a type, and a read asks for the inline field's type. An
//   entry of another type is reported once and the inline value is used.
// - A value is copied in as bytes, MAX_VALUE_SIZE at most, so it is plain
//   data: a number, a vector, a color, a handle, a reference.
// - `get` reads when it is called. A reader that wants a value that follows
//   the game reads every tick, and one that wants it fixed reads once.
// - `global()` is one dictionary for the whole game, for values many readers
//   share. A dictionary of the caller's own puts it last in its chain.
//
// A writer sets the entry a slot is connected to, for every reader of it:
//
//   slots.write(h.hp, f32(4), slots.scope_of(h.owner))
//
// What the inspector offers to connect a slot to are the declared entries of
// the inline field's type:
//
//   slots.declare("speed", f32, "Units per second of the level's conveyor")
//
// - Declaring an entry makes no value. It says the name and the type exist,
//   so the picker can list it before the game runs.
//
// A reader that belongs to an object asks for the object's dictionary:
//
//   speed := slots.get(m.speed, m._speed, slots.scope_of(m.owner))
//
// - `scope_of` is the global dictionary until a package installs a scope
//   (`scope_install`), a way to find an object's dictionary. The blackboard
//   plugin installs one: the nearest Blackboard component on the object or
//   above it, with the global dictionary last in its chain.
// - `scope_entries` lists what a scope offers an object, for the inspector,
//   and `label` is what a connection is shown as.
//
// Dictionaries are not shared between threads. Names and declarations are.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import core "moonhug:libs/core"
import log "moonhug:libs/log"

// A slot: the entry it is connected to, or INLINE.
Slot :: distinct u32

// Not connected: the value is the inline field's.
INLINE :: Slot(0)

// The largest value an entry holds, in bytes: a 4x4 matrix of f32.
MAX_VALUE_SIZE :: 64

@(private) _names:      [dynamic]string // by slot number, 0 is ""
@(private) _by_name:    map[string]Slot
@(private) _declared:   [dynamic]Decl
@(private) _names_lock: sync.Mutex
@(private) _global:     Dict
@(private) _reported:   map[Slot]typeid // an entry read as the wrong type, reported once

@(init)
_slots_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	_names = make([dynamic]string, alloc)
	append(&_names, "")
	_by_name = make(map[string]Slot, alloc)
	_declared = make([dynamic]Decl, alloc)
	_reported = make(map[Slot]typeid, alloc)
	_global.entries = make(map[Slot]Entry, alloc)
}

// The slot connected to entry `name`. An empty name is INLINE. Names are kept
// for the life of the process.
entry :: proc(name: string) -> Slot {
	if name == "" do return INLINE
	sync.guard(&_names_lock)
	if s, ok := _by_name[name]; ok do return s
	owned := strings.clone(name, runtime.default_allocator())
	s := Slot(len(_names))
	append(&_names, owned)
	_by_name[owned] = s
	return s
}

// The name of the entry `s` is connected to, "" for INLINE.
name :: proc(s: Slot) -> string {
	sync.guard(&_names_lock)
	if int(s) >= len(_names) do return ""
	return _names[s]
}

// A declared entry: a name the game fills, and the type of its value.
Decl :: struct {
	name: string,
	type: typeid,
	doc:  string, // one line, for the picker's tooltip
}

// Says entry `name` of type `T` exists, so the inspector offers it for slots
// of that type. Declaring it again replaces the type and the text.
declare :: proc(name: string, T: typeid, doc := "") {
	if name == "" do return
	sync.guard(&_names_lock)
	alloc := runtime.default_allocator()
	for &d in _declared do if d.name == name {
		delete(d.doc, alloc)
		d.type = T
		d.doc = strings.clone(doc, alloc)
		return
	}
	append(&_declared, Decl{name = strings.clone(name, alloc), type = T, doc = strings.clone(doc, alloc)})
}

// Every declared entry of type `T`, in the order declared. Temp-allocated.
declared_of :: proc(T: typeid) -> []Decl {
	sync.guard(&_names_lock)
	out := make([dynamic]Decl, context.temp_allocator)
	for d in _declared do if d.type == T do append(&out, d)
	return out[:]
}

// One entry of a dictionary.
Entry :: struct {
	type: typeid,
	// Set: the value is computed on every read, written to `out`.
	read: proc(out: rawptr, user: rawptr),
	user: rawptr,
	data: [MAX_VALUE_SIZE]u8,
}

// Entries by name, and the dictionary looked in when this one has none.
Dict :: struct {
	entries: map[Slot]Entry,
	parent:  ^Dict,
	// Where `write` puts a value for an entry this dictionary has, nil for
	// this dictionary itself. A dictionary rebuilt from authored data sends
	// writes to one looked in before it, so a rebuild keeps them.
	writes:  ^Dict,
}

// The game-wide dictionary.
global :: proc() -> ^Dict {
	return &_global
}

// Sets entry `name` of `d` to `value`.
set :: proc(d: ^Dict, name: string, value: $T) {
	put(d, entry(name), value)
}

// Sets the entry `slot` connects to. What `set` does, for a caller that holds
// the slot and not the name.
put :: proc(d: ^Dict, slot: Slot, value: $T) {
	#assert(size_of(T) <= MAX_VALUE_SIZE, "a slot value holds MAX_VALUE_SIZE bytes at most")
	v := value
	put_raw(d, slot, T, &v)
}

// Sets the entry `slot` connects to, to the `T` at `value`, for a caller that
// knows the type only at run time: a union's active variant.
put_raw :: proc(d: ^Dict, slot: Slot, T: typeid, value: rawptr) {
	if slot == INLINE do return
	size := type_info_of(T).size
	fmt.assertf(size <= MAX_VALUE_SIZE, "slots: a %v is %d bytes, a value holds MAX_VALUE_SIZE (%d) at most", T, size, MAX_VALUE_SIZE)
	_ensure(d)
	e := Entry{type = T}
	runtime.mem_copy(&e.data[0], value, size)
	d.entries[slot] = e
}

// Sets entry `name` of `d` to a value `read` computes on every read. `user`
// is handed back to it, and must outlive the entry.
set_proc :: proc(d: ^Dict, name: string, $T: typeid, read: proc(out: ^T, user: rawptr), user: rawptr = nil) {
	#assert(size_of(T) <= MAX_VALUE_SIZE, "a slot value holds MAX_VALUE_SIZE bytes at most")
	if name == "" do return
	_ensure(d)
	d.entries[entry(name)] = Entry{type = T, read = cast(proc(out: rawptr, user: rawptr))read, user = user}
}

// Takes entry `name` out of `d`. Readers get the next dictionary's, or their
// inline value.
remove :: proc(d: ^Dict, name: string) {
	if d.entries == nil do return
	delete_key(&d.entries, entry(name))
}

// Frees `d`'s entries. The parent is left alone.
destroy :: proc(d: ^Dict) {
	delete(d.entries)
	d.entries = nil
}

// The value of a slot: the entry `slot` is connected to, looked up in `d` and
// then along its parents, or `inline` when the slot is not connected, no
// dictionary has the entry, or the entry is of another type than `T`.
get :: proc(slot: Slot, inline: $T, d: ^Dict) -> T {
	if v, ok := lookup(slot, T, d); ok do return v
	return inline
}

// The entry `slot` is connected to, as a `T`. False for INLINE, for an entry
// no dictionary in the chain has, and for one of another type, which is
// reported once.
lookup :: proc(slot: Slot, $T: typeid, d: ^Dict) -> (value: T, ok: bool) {
	#assert(size_of(T) <= MAX_VALUE_SIZE, "a slot value holds MAX_VALUE_SIZE bytes at most")
	ok = lookup_raw(slot, T, d, &value)
	return
}

// Whether a dictionary in `d`'s chain has the entry `slot` is connected to.
has :: proc(slot: Slot, d: ^Dict) -> bool {
	if slot == INLINE do return false
	for at := d; at != nil; at = at.parent {
		if slot in at.entries do return true
	}
	return false
}

// Writes `value` to the entry `slot` is connected to, for every reader of
// it: in the first dictionary of `d`'s chain that has the entry, or where
// that dictionary sends writes (`Dict.writes`).
// False, and nothing written:
// - for INLINE, where the value is the caller's own field,
// - for an entry no dictionary in the chain has. A write makes no entry:
//   one made in the game-wide dictionary during a run would outlive the run.
//   Whoever owns the entry makes it first, with `set` or an authored entry.
// - for an entry of another type than `T`, which is reported once,
// - for a computed entry (`set_proc`), whose value is code's.
write :: proc(slot: Slot, value: $T, d: ^Dict) -> bool {
	#assert(size_of(T) <= MAX_VALUE_SIZE, "a slot value holds MAX_VALUE_SIZE bytes at most")
	if slot == INLINE do return false
	for at := d; at != nil; at = at.parent {
		e, has := &at.entries[slot]
		if !has do continue
		if e.type != T {
			_report_type(slot, e.type, T)
			return false
		}
		if e.read != nil do return false
		put(at.writes != nil ? at.writes : at, slot, value)
		return true
	}
	return false
}

@(private)
_ensure :: proc(d: ^Dict) {
	if d.entries == nil do d.entries = make(map[Slot]Entry, runtime.default_allocator())
}

@(private)
_report_type :: proc(slot: Slot, have, want: typeid) {
	{
		sync.guard(&_names_lock)
		if seen, ok := _reported[slot]; ok && seen == want do return
		_reported[slot] = want
	}
	log.errorf("slots: entry %q holds a %v and a slot reads it as a %v, the slot's inline value is used", name(slot), have, want)
}

// An entry a scope offers an object: the slot that connects to it, the name
// it is shown by, and what it comes from, for the picker ("Enemy").
//
// The slot is the entry's key, and need not be its name: a Blackboard's
// entry is keyed by an id that stays when the entry is renamed, so a rename
// breaks no connection, and its name is read where it is shown.
Scope_Entry :: struct {
	slot: Slot,
	name: string,
	from: string,
}

// How a package finds the dictionary of an object.
Scope :: struct {
	// The dictionary readers on `owner` look in, nil for none of this scope's.
	dict_of:    proc(owner: core.Transform_Handle) -> ^Dict,
	// The entries of type `T` it offers `owner`, nearest first.
	// Temp-allocated.
	entries_of: proc(owner: core.Transform_Handle, T: typeid) -> []Scope_Entry,
	// Where the entry `slot` connects to is for `owner`, false when the scope
	// has no such entry. Temp-allocated.
	origin_of:  proc(owner: core.Transform_Handle, slot: Slot) -> (Origin, bool),
}

// Where a slot's entry is: the name it is shown by ("lift"), what holds it
// ("Squad B", "Global", "" when nothing does), and the object that holds it,
// {} when no object does.
Origin :: struct {
	name:   string,
	from:   string,
	holder: core.Transform_Handle,
}

@(private) _scope: Scope

// Installs the scope `scope_of` and `scope_entries` ask. One scope at a
// time: a later install replaces it.
scope_install :: proc(scope: Scope) {
	_scope = scope
}

// The dictionary a reader on `owner` looks in: the installed scope's, or the
// global one when no scope is installed or it has none for the object.
scope_of :: proc(owner: core.Transform_Handle) -> ^Dict {
	if _scope.dict_of != nil {
		if d := _scope.dict_of(owner); d != nil do return d
	}
	return &_global
}

// The entries of type `T` the installed scope offers `owner`. Empty without a
// scope. Temp-allocated.
scope_entries :: proc(owner: core.Transform_Handle, T: typeid) -> []Scope_Entry {
	if _scope.entries_of == nil do return nil
	return _scope.entries_of(owner, T)
}

// What a slot's connection is shown as for a reader on `owner`: the name the
// installed scope gives the entry, else the slot's own name, which is the
// entry's name for an entry code fills.
label :: proc(owner: core.Transform_Handle, slot: Slot) -> string {
	return origin(owner, slot).name
}

// Where the entry a slot connects to is for a reader on `owner`: the
// installed scope's answer ("lift" on "Squad B"), else the slot's own name,
// from "Global" when the game-wide dictionary has the entry, from "" when
// nothing has it.
origin :: proc(owner: core.Transform_Handle, slot: Slot) -> Origin {
	if _scope.origin_of != nil {
		if o, ok := _scope.origin_of(owner, slot); ok do return o
	}
	if slot in _global.entries do return {name = name(slot), from = "Global"}
	return {name = name(slot)}
}

// lookup for a type known only at run time: copies the value of the entry
// `slot` is connected to into `out`, which holds a `T`. False as lookup is.
lookup_raw :: proc(slot: Slot, T: typeid, d: ^Dict, out: rawptr) -> bool {
	if slot == INLINE || out == nil do return false
	size := type_info_of(T).size
	if size > MAX_VALUE_SIZE do return false
	for at := d; at != nil; at = at.parent {
		e, has := &at.entries[slot]
		if !has do continue
		if e.type != T {
			_report_type(slot, e.type, T)
			return false
		}
		if e.read != nil {
			e.read(out, e.user)
		} else {
			runtime.mem_copy(out, &e.data[0], size)
		}
		return true
	}
	return false
}

