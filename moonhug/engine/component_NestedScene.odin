package engine

@(component)
@(typ_guid={guid = "b8f4a1c2-5e7d-4a9b-8c3f-2d1e6a0b9c7d"})
NestedScene :: struct {
    using base: CompData `inspect:"-"`,
    scene_guid: Asset_GUID,
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
