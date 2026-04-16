package engine

import "core:encoding/json"

@(component)
@(typ_guid={guid = "b8f4a1c2-5e7d-4a9b-8c3f-2d1e6a0b9c7d"})
NestedScene :: struct {
    using base: CompData `inspect:"-"`,
    scene_guid: Asset_GUID,
}

transform_is_nested_owned :: proc(tH: Transform_Handle) -> bool {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return false
    return t.nested_owned
}

transform_find_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if t == nil do return {}
        if _, ns := transform_get_comp(current, NestedScene); ns != nil {
            return current
        }
        current = Transform_Handle(t.parent.handle)
    }
    return {}
}

transform_nested_enclosing_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {}
    if !t.nested_owned {
        if _, ns := transform_get_comp(tH, NestedScene); ns != nil {
            return tH
        }
        return {}
    }
    current := Transform_Handle(t.parent.handle)
    for pool_valid(&w.transforms, Handle(current)) {
        ct := pool_get(&w.transforms, Handle(current))
        if ct == nil do return {}
        if !ct.nested_owned {
            if _, ns := transform_get_comp(current, NestedScene); ns != nil {
                return current
            }
            return {}
        }
        current = Transform_Handle(ct.parent.handle)
    }
    return {}
}

nested_scene_resolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    _nested_scene_unresolve(host_tH)

    _, ns := transform_get_comp(host_tH, NestedScene)
    if ns == nil do return
    guid := ns.scene_guid
    empty_guid := Asset_GUID{}
    if guid == empty_guid do return

    if !ctx_get().is_playmode {
        if existing, had := scene_lib[guid]; had {
            delete(existing)
            delete_key(&scene_lib, guid)
        }
    }
    raw, ok := scene_lib[guid]
    if !ok {
        if !scene_lib_register(guid) do return
        raw, ok = scene_lib[guid]
        if !ok do return
    }

    sf: SceneFile
    if err := json.unmarshal(raw, &sf); err != nil do return
    defer scene_file_destroy(&sf)

    host_scene := host_t.scene
    nested_root_tH := _scene_load_as_child(&sf, host_tH, host_scene)
    if nested_root_tH == {} do return

    _mark_subtree_nested_owned(nested_root_tH)
    _scene_resolve_nested_in_subtree(nested_root_tH)
}

_mark_subtree_nested_owned :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return
    t.nested_owned = true
    for &c in t.components {
        raw := world_pool_get(w, c.handle)
        if raw == nil do continue
        base := cast(^CompData)raw
        base.nested_owned = true
    }
    for child in t.children {
        _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
}

_nested_scene_unresolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    to_destroy := make([dynamic]Transform_Handle, 0, len(host_t.children), context.temp_allocator)
    for child in host_t.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        if ct.nested_owned {
            append(&to_destroy, Transform_Handle(child.handle))
        }
    }
    for tH in to_destroy {
        transform_destroy(tH)
    }
}

_scene_resolve_nested_in_subtree :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return

    if _, ns := transform_get_comp(root_tH, NestedScene); ns != nil {
        nested_scene_resolve(root_tH)
        return
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
    }
}

scene_resolve_all_nested :: proc(root_tH: Transform_Handle) {
    _scene_resolve_nested_in_subtree(root_tH)
}

on_validate_NestedScene :: proc(ns: ^NestedScene) {
    if ctx_get().is_playmode do return
    nested_scene_resolve(ns.owner)
}

_nested_scene_expand_host :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    owned, ns := transform_get_comp(host_tH, NestedScene)
    if ns == nil do return
    guid := ns.scene_guid
    empty_guid := Asset_GUID{}

    transform_remove_comp(host_tH, owned.handle)

    if guid == empty_guid do return

    if _, ok := scene_lib[guid]; !ok {
        if !scene_lib_register(guid) do return
    }

    nested_root_tH := scene_instantiate_guid(guid, host_tH)
    if nested_root_tH == {} do return

    nested_root := pool_get(&w.transforms, Handle(nested_root_tH))
    if nested_root == nil do return

    for c in nested_root.components {
        if world_pool_valid(w, c.handle) {
            raw := world_pool_get(w, c.handle)
            if raw != nil {
                base := cast(^CompData)raw
                base.owner = host_tH
            }
        }
        append(&host_t.components, c)
    }
    clear(&nested_root.components)

    for child in nested_root.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        ct.parent = make_transform_ref(host_tH)
        append(&host_t.children, child)
    }
    clear(&nested_root.children)

    transform_destroy(nested_root_tH)

    _scene_expand_nested_in_subtree(host_tH)
}

_scene_expand_nested_in_subtree :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return

    if _, ns := transform_get_comp(root_tH, NestedScene); ns != nil {
        _nested_scene_expand_host(root_tH)
        return
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        _scene_expand_nested_in_subtree(Transform_Handle(child.handle))
    }
}
