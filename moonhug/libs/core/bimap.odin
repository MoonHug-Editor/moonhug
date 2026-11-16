package core

Bimap :: struct($K, $V: typeid) {
    forward:  map[K]V,
    backward: map[V]K,
}

// Pairs `key` with `val`. A pair that either of them was in is taken out
// first, so the two maps always mirror each other.
bimap_insert :: proc(b: ^Bimap($K, $V), key: K, val: V) {
    if old_val, had := b.forward[key]; had && old_val != val do delete_key(&b.backward, old_val)
    if old_key, had := b.backward[val]; had && old_key != key do delete_key(&b.forward, old_key)
    b.forward[key]  = val
    b.backward[val] = key
}

bimap_remove :: proc{
    bimap_remove_by_key,
    bimap_remove_by_val,
}

bimap_get :: proc{
    bimap_get_by_key,
    bimap_get_by_val,
}

bimap_has :: proc{
    bimap_has_by_key,
    bimap_has_by_val,
}

cleanup_Bimap :: proc(b: ^Bimap($K, $V)) {
    delete(b.forward)
    delete(b.backward)
}

@(private="file")
bimap_has_by_key :: proc(b: ^Bimap($K, $V), key: K) -> bool {
    _, has := b.forward[key]
    return has
}

@(private="file")
bimap_has_by_val :: proc(b: ^Bimap($K, $V), val: V) -> bool {
    _, has := b.backward[val]
    return has
}

@(private="file")
bimap_get_by_key :: proc(b: ^Bimap($K, $V), key: K) -> (V, bool) {
    return b.forward[key]
}

@(private="file")
bimap_get_by_val :: proc(b: ^Bimap($K, $V), val: V) -> (K, bool) {
    return b.backward[val]
}

bimap_remove_by_key :: proc(b: ^Bimap($K, $V), key: K) -> bool {
    val, ok := b.forward[key]
    if !ok do return false
    delete_key(&b.forward, key)
    delete_key(&b.backward, val)
    return true
}

bimap_remove_by_val :: proc(b: ^Bimap($K, $V), val: V) -> bool {
    key, ok := b.backward[val]
    if !ok do return false
    delete_key(&b.forward, key)
    delete_key(&b.backward, val)
    return true
}
