package engine

// World-level pool dispatch. The pools themselves (Pool, Handle, Pool_Entry)
// live in moonhug:engine/core — this file is the part that needs a World:
// routing a handle to the world's pool_table entry for its TypeKey.

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
