package engine

import "core:fmt"

MAX :: 1024

Handle :: struct {
    index:      u32,
    generation: u16,
    type_key:   TypeKey,
}

// Pool internals (_-prefixed fields) are private: the slot layout is an
// implementation detail that may change (e.g. SoA columns), so nothing
// outside this file touches them. Consumers hold Handles and reach data
// through pool_get / pool_iterator — see docs/Components.md for the contract.
Pool :: struct($T: typeid, $N: int = MAX) {
    _slots:     [N]struct {
        generation: u16,
        alive:      bool,
        data:       T,
    },
    _freelist:  [N]u32,
    _free_head: int,
    count:      int,
}

pool_init :: proc(p: ^Pool($T, $N)) {
    for i in 0..<N {
        p._freelist[i] = u32(i)
        p._slots[i].generation = 1
    }
    p._free_head = N - 1
}

pool_create :: proc(p: ^Pool($T, $N)) -> (Handle, ^T) {
    if p.count >= N {
        if key, key_ok := get_type_key_by_typeid(T); key_ok {
            panic(fmt.tprintf("pool is full: type_key=%v count=%d max=%d", key, p.count, N))
        }
        panic(fmt.tprintf("pool is full: type=%v count=%d max=%d", typeid_of(T), p.count, N))
    }
    idx := p._freelist[p._free_head]
    p._free_head -= 1
    p.count += 1
    slot := &p._slots[idx]
    slot.alive = true
    // A recycled slot keeps the destroyed instance's bytes. Hand out zeroed
    // memory: loaders unmarshal IN PLACE and json:"-" fields (nested_owned,
    // owner) are never in the payload — stale values would survive. A stale
    // nested_owned=true makes every save silently skip the component.
    slot.data = {}
    handle := Handle{ index = idx, generation = slot.generation, type_key = INVALID_TYPE_KEY }
    return handle, &slot.data
}

pool_destroy :: proc(p: ^Pool($T, $N), h: Handle) {
    assert(pool_valid(p, h), "invalid handle")
    slot := &p._slots[h.index]
    slot.alive      = false
    slot.generation += 1
    p._free_head += 1
    p._freelist[p._free_head] = h.index
    p.count -= 1
}

pool_get :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    if !pool_valid(pool, handle) do return nil
    return &pool._slots[handle.index].data
}
pool_get_assert :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    assert(pool_valid(pool, handle))
    return &pool._slots[handle.index].data
}

pool_valid :: proc(p: ^Pool($T, $N), h: Handle) -> bool {
    if h.index >= u32(N) do return false
    slot := &p._slots[h.index]
    return slot.alive && slot.generation == h.generation
}

// Iteration over alive components:
//
//	it := pool_iterator(pool)
//	for comp, h in pool_next(&it) { ... }
//
// A nil pool yields an empty iterator (no caller-side guard). The handle
// carries INVALID_TYPE_KEY — pools don't know their TypeKey, callers stamp
// it when they need a typed handle. Destroying any component (including the
// current one) mid-iteration is safe; components created mid-iteration may
// or may not be visited.
Pool_Iterator :: struct($T: typeid, $N: int) {
    pool:  ^Pool(T, N),
    index: int,
}

pool_iterator :: proc(p: ^Pool($T, $N)) -> Pool_Iterator(T, N) {
    return {pool = p}
}

pool_next :: proc(it: ^Pool_Iterator($T, $N)) -> (data: ^T, h: Handle, ok: bool) {
    if it.pool == nil do return
    for it.index < N {
        i := it.index
        it.index += 1
        slot := &it.pool._slots[i]
        if slot.alive {
            return &slot.data, Handle{ index = u32(i), generation = slot.generation, type_key = INVALID_TYPE_KEY }, true
        }
    }
    return
}

Pool_Entry :: struct {
    pool:           rawptr,
    get_fn:         proc(pool: rawptr, handle: Handle) -> rawptr,
    valid_fn:       proc(pool: rawptr, handle: Handle) -> bool,
    create_fn:      proc(pool: rawptr) -> (Handle, rawptr),
    destroy_fn:     proc(pool: rawptr, handle: Handle),
    collect_fn:     proc(comp: rawptr, sf: rawptr),
}

pool_make_entry :: proc(p: ^Pool($T, $N)) -> Pool_Entry {
    return Pool_Entry{
        pool = p,
        get_fn = proc(pool: rawptr, handle: Handle) -> rawptr {
            p := cast(^Pool(T, N))pool
            return pool_get(p, handle)
        },
        valid_fn = proc(pool: rawptr, handle: Handle) -> bool {
            p := cast(^Pool(T, N))pool
            return pool_valid(p, handle)
        },
        create_fn = proc(pool: rawptr) -> (Handle, rawptr) {
            p := cast(^Pool(T, N))pool
            return pool_create(p)
        },
        destroy_fn = proc(pool: rawptr, handle: Handle) {
            p := cast(^Pool(T, N))pool
            pool_destroy(p, handle)
        },
    }
}

// pool_table is a [TypeKey]Pool_Entry — an array sized to the enumerator count,
// NOT the u16 range. An unresolved/garbage handle can carry INVALID_TYPE_KEY
// (max(u16)) or any out-of-range value, so guard before indexing or it panics.
_type_key_valid :: proc(k: TypeKey) -> bool {
    return u16(k) < u16(len(TypeKey))
}

world_pool_get :: proc(w: ^World, handle: Handle) -> rawptr {
    if !_type_key_valid(handle.type_key) do return nil
    entry := w.pool_table[handle.type_key]
    if entry.get_fn == nil do return nil
    return entry.get_fn(entry.pool, handle)
}

world_pool_valid :: proc(w: ^World, handle: Handle) -> bool {
    if !_type_key_valid(handle.type_key) do return false
    entry := w.pool_table[handle.type_key]
    if entry.valid_fn == nil do return false
    return entry.valid_fn(entry.pool, handle)
}

world_pool_create :: proc(w: ^World, type_key: TypeKey) -> (Handle, rawptr) {
    if !_type_key_valid(type_key) do return {}, nil
    entry := w.pool_table[type_key]
    if entry.create_fn == nil do return {}, nil
    h, ptr := entry.create_fn(entry.pool)
    h.type_key = type_key
    return h, ptr
}

world_pool_destroy :: proc(w: ^World, handle: Handle) {
    if !_type_key_valid(handle.type_key) do return
    entry := w.pool_table[handle.type_key]
    if entry.destroy_fn == nil do return
    entry.destroy_fn(entry.pool, handle)
}

world_pool_collect :: proc(w: ^World, handle: Handle, sf: ^SceneFile) {
    if !_type_key_valid(handle.type_key) do return
    entry := w.pool_table[handle.type_key]
    if entry.get_fn == nil do return
    ptr := entry.get_fn(entry.pool, handle)
    if ptr == nil do return
    if entry.collect_fn != nil {
        entry.collect_fn(ptr, sf)
        return
    }
    // Registered external components (no generated collect_fn) serialize as
    // guid-tagged blob records.
    if desc, ok := component_registry[handle.type_key]; ok {
        _ext_collect_component(desc, ptr, sf)
    }
}
