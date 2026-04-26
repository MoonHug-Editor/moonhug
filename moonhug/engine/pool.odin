package engine

import "core:fmt"

MAX :: 1024

Handle :: struct {
    index:      u32,
    generation: u16,
    type_key:   TypeKey,
}

Pool :: struct($T: typeid, $N: int = MAX) {
    slots:     [N]struct {
        generation: u16,
        alive:      bool,
        data:       T,
    },
    freelist:  [N]u32,
    free_head: int,
    count:     int,
}

pool_init :: proc(p: ^Pool($T, $N)) {
    for i in 0..<N {
        p.freelist[i] = u32(i)
        p.slots[i].generation = 1
    }
    p.free_head = N - 1
}

pool_create :: proc(p: ^Pool($T, $N)) -> (Handle, ^T) {
    if p.count >= N {
        if key, key_ok := get_type_key_by_typeid(T); key_ok {
            panic(fmt.tprintf("pool is full: type_key=%v count=%d max=%d", key, p.count, N))
        }
        panic(fmt.tprintf("pool is full: type=%v count=%d max=%d", typeid_of(T), p.count, N))
    }
    idx := p.freelist[p.free_head]
    p.free_head -= 1
    p.count += 1
    slot := &p.slots[idx]
    slot.alive = true
    handle := Handle{ index = idx, generation = slot.generation, type_key = INVALID_TYPE_KEY }
    return handle, &slot.data
}

pool_destroy :: proc(p: ^Pool($T, $N), h: Handle) {
    assert(pool_valid(p, h), "invalid handle")
    slot := &p.slots[h.index]
    slot.alive      = false
    slot.generation += 1
    p.free_head += 1
    p.freelist[p.free_head] = h.index
    p.count -= 1
}

pool_get :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    if !pool_valid(pool, handle) do return nil
    return &pool.slots[handle.index].data
}
pool_get_assert :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    assert(pool_valid(pool, handle))
    return &pool.slots[handle.index].data
}

pool_valid :: proc(p: ^Pool($T, $N), h: Handle) -> bool {
    if h.index >= u32(N) do return false
    slot := &p.slots[h.index]
    return slot.alive && slot.generation == h.generation
}

pool_iter :: proc(p: ^Pool($T, $N), body: proc(h: Handle, data: ^T)) {
    for i in 0..<N {
        slot := &p.slots[i]
        if slot.alive {
            body(Handle{ index = u32(i), generation = slot.generation, type_key = INVALID_TYPE_KEY }, &slot.data)
        }
    }
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

world_pool_get :: proc(w: ^World, handle: Handle) -> rawptr {
    entry := w.pool_table[handle.type_key]
    if entry.get_fn == nil do return nil
    return entry.get_fn(entry.pool, handle)
}

world_pool_valid :: proc(w: ^World, handle: Handle) -> bool {
    entry := w.pool_table[handle.type_key]
    if entry.valid_fn == nil do return false
    return entry.valid_fn(entry.pool, handle)
}

world_pool_create :: proc(w: ^World, type_key: TypeKey) -> (Handle, rawptr) {
    entry := w.pool_table[type_key]
    if entry.create_fn == nil do return {}, nil
    h, ptr := entry.create_fn(entry.pool)
    h.type_key = type_key
    return h, ptr
}

world_pool_destroy :: proc(w: ^World, handle: Handle) {
    entry := w.pool_table[handle.type_key]
    if entry.destroy_fn == nil do return
    entry.destroy_fn(entry.pool, handle)
}

world_pool_collect :: proc(w: ^World, handle: Handle, sf: ^SceneFile) {
    entry := w.pool_table[handle.type_key]
    if entry.collect_fn == nil do return
    ptr := entry.get_fn(entry.pool, handle)
    if ptr == nil do return
    entry.collect_fn(ptr, sf)
}
