package engine

CompData :: struct {
    owner: Transform_Handle `json:"-"`,
    local_id: Local_ID `inspect:"-"`,
    enabled: bool,
}

comp_init_base :: proc(comp: rawptr, owner: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(owner))
    base := cast(^CompData)comp
    base.owner = owner
    base.enabled = true
    if t != nil && t.scene != nil {
        base.local_id = scene_next_id(t.scene)
    }
}

transform_add_comp :: proc(tH: Transform_Handle, key: TypeKey) -> (Owned, rawptr) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {}, nil

    handle, pComp := world_pool_create(w, key)
    if pComp == nil do return {}, nil

    comp_init_base(pComp, tH)

    base := cast(^CompData)pComp
    owned := Owned{handle = handle, local_id = base.local_id}
    append(&t.components, owned)
    return owned, pComp
}

transform_get_or_add_comp :: proc(tH: Transform_Handle, $T: typeid) -> (Owned, ^T) {
    owned, pComp := transform_get_comp(tH, T)
    if pComp != nil do return owned, pComp
    key, ok := get_type_key_by_typeid(T)
    if !ok do return {}, nil
    new_owned, raw := transform_add_comp(tH, key)
    return new_owned, cast(^T)raw
}

transform_remove_comp :: proc(tH: Transform_Handle, comp_handle: Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    for i in 0 ..< len(t.components) {
        c := t.components[i]
        if c.handle.index == comp_handle.index && c.handle.generation == comp_handle.generation && c.handle.type_key == comp_handle.type_key {
            world_pool_destroy(w, comp_handle)
            ordered_remove(&t.components, i)
            return
        }
    }
}

@(component)
@(typ_guid={guid = "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"})
SpriteRenderer :: struct {
    using base: CompData `inspect:"-"`,
    texture: Asset_GUID,
    color:   [4]f32 `decor:color()`,
}

sprite_renderer_default :: proc(sr: ^SpriteRenderer) {
    sr.color = {1, 1, 1, 1}
}

@(component)
@(typ_guid={guid = "adaf3551-4704-4255-ad91-fde59441dc53"})
Script :: struct {
    using base: CompData `inspect:"-"`,
}
