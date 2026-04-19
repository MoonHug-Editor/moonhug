package engine

import "core:math/linalg"
import "core:strings"

Transform_Handle :: distinct Handle

@(poolable)
@(typ_guid={guid = "312927b7-3c4a-4929-9807-8216baf26a68"})
Transform :: struct {
    local_id: Local_ID `inspect:"-"`,
    name: string,
    is_active: bool,
    destroy: bool `json:"-"`,
    nested_owned: bool `json:"-"`,
    position: [3]f32,
    rotation: [4]f32,
    scale:    [3]f32,
    render_layer: u32,
    scene: ^Scene `json:"-"`,
    parent:   Ref `inspect:"-"`,
    children: [dynamic]Ref `inspect:"-"`,
    components: [dynamic]Owned `inspect:"-"`,
}

make_transform_ref :: proc(tH: Transform_Handle) -> Ref {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    lid: Local_ID
    if t != nil do lid = t.local_id
    return Ref{ pptr = PPtr{local_id = lid}, handle = Handle(tH) }
}

transform_new :: proc(name: string, parentH: Transform_Handle = {}) -> Transform_Handle {
    w := ctx_world()
    s := sm_scene_get_active()

    tHandle, t := pool_create(&w.transforms)
    tHandle.type_key = .Transform
    tH := Transform_Handle(tHandle)
    t.name = strings.clone(name)
    t.is_active = true
    t.rotation = QUAT_IDENTITY
    t.scale = {1, 1, 1}
    t.render_layer = 1

    if s != nil {
        t.local_id = scene_next_id(s)
        t.scene = s
    }

    actual_parentH := parentH
    if !pool_valid(&w.transforms, Handle(actual_parentH)) &&
        s != nil && pool_valid(&w.transforms, s.root.handle)
    {
        actual_parentH = Transform_Handle(s.root.handle)
    }

    transform_set_parent(tH, actual_parentH)

    return tH
}

transform_destroy :: proc(tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    if pool_valid(&w.transforms, t.parent.handle) {
        transform_unlink_from_parent(tH)
    } else {
        s := sm_scene_get_active()
        if s != nil && s.root.handle == Handle(tH) do scene_clear_root(s)
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        ct := pool_get(&w.transforms, child.handle)
        if ct != nil {
            ct.parent = {}
            transform_destroy(Transform_Handle(child.handle))
        }
    }
    delete(t.children)

    transform_destroy_components(tH)
    delete(t.name)
    t^ = {}
    pool_destroy(&w.transforms, Handle(tH))
}

transform_unlink_from_parent :: proc(tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    if !pool_valid(&w.transforms, t.parent.handle) do return

    p := pool_get(&w.transforms, t.parent.handle)
    for i in 0 ..< len(p.children) {
        if p.children[i].handle == Handle(tH) {
            ordered_remove(&p.children, i)
            break
        }
    }
    t.parent = {}
}

_transform_remap_scene :: proc(tH: Transform_Handle, s: ^Scene) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    t.scene = s
    if s != nil && !t.nested_owned {
        t.local_id = scene_next_id(s)
        for &c in t.components {
            raw := world_pool_get(w, c.handle)
            if raw == nil do continue
            base := cast(^CompData)raw
            base.local_id = scene_next_id(s)
            c.local_id = base.local_id
        }
    }
    for child in t.children {
        _transform_remap_scene(Transform_Handle(child.handle), s)
    }
}

transform_set_parent :: proc(tH: Transform_Handle, new_parent: Transform_Handle, index: int = -1) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    if pool_valid(&w.transforms, t.parent.handle) {
        transform_unlink_from_parent(tH)
    } else {
        s := sm_scene_get_active()
        if s != nil && s.root.handle == Handle(tH) do scene_clear_root(s)
    }

    new_scene: ^Scene
    if pool_valid(&w.transforms, Handle(new_parent)) {
        np := pool_get(&w.transforms, Handle(new_parent))
        new_scene = np.scene
    } else {
        new_scene = sm_scene_get_active()
    }

    if new_scene != t.scene {
        _transform_remap_scene(tH, new_scene)
    }

    t.parent = make_transform_ref(new_parent)
    if pool_valid(&w.transforms, Handle(new_parent)) {
        np := pool_get(&w.transforms, Handle(new_parent))
        child_ref := make_transform_ref(tH)
        if index >= 0 && index <= len(np.children) {
            inject_at(&np.children, index, child_ref)
        } else {
            append(&np.children, child_ref)
        }
    } else {
        if new_scene != nil {
            new_scene.root = make_transform_ref(tH)
        }
    }
}

transform_active_in_hierarchy :: proc(tH: Transform_Handle) -> bool {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if !t.is_active do return false
        current = Transform_Handle(t.parent.handle)
    }
    return true
}

Transform_World :: struct {
    position: [3]f32,
    rotation: [4]f32,
    scale:    [3]f32,
}

_quat_safe :: proc(q: [4]f32) -> [4]f32 {
    if q == {0, 0, 0, 0} do return QUAT_IDENTITY
    return q
}

transform_world :: proc(tH: Transform_Handle) -> Transform_World {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {{}, QUAT_IDENTITY, {1, 1, 1}}

    rot := _quat_safe(t.rotation)

    if !pool_valid(&w.transforms, t.parent.handle) {
        return {t.position, rot, t.scale}
    }

    p := transform_world(Transform_Handle(t.parent.handle))

    world_scale := p.scale * t.scale
    world_rot   := quat_from_native(quat_to_native(p.rotation) * quat_to_native(rot))
    world_pos   := p.position + linalg.quaternion128_mul_vector3(quat_to_native(p.rotation), t.position * p.scale)

    return {world_pos, world_rot, world_scale}
}

transform_world_position :: proc(tH: Transform_Handle) -> [3]f32 { return transform_world(tH).position }
transform_world_rotation :: proc(tH: Transform_Handle) -> [4]f32 { return transform_world(tH).rotation }
transform_world_scale    :: proc(tH: Transform_Handle) -> [3]f32 { return transform_world(tH).scale }

_transform_append_name_suffix :: proc(tH: Transform_Handle, suffix: string) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    old := t.name
    t.name = strings.concatenate({old, suffix})
    delete(old)
}

transform_get_sibling_index :: proc(tH: Transform_Handle) -> int {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return -1

    if pool_valid(&w.transforms, t.parent.handle) {
        p := pool_get(&w.transforms, t.parent.handle)
        for i in 0 ..< len(p.children) {
            if p.children[i].handle == Handle(tH) do return i
        }
    } else {
        s := sm_scene_get_active()
        if s != nil && s.root.handle == Handle(tH) do return 0
    }
    return -1
}

transform_tick_destroy :: proc() {
    w := ctx_world()
    to_destroy: [dynamic]Transform_Handle
    defer delete(to_destroy)
    for i in 0..<len(w.transforms.slots) {
        slot := &w.transforms.slots[i]
        if !slot.alive do continue
        if slot.data.destroy {
            handle := Handle{ index = u32(i), generation = slot.generation, type_key = .Transform }
            append(&to_destroy, Transform_Handle(handle))
        }
    }
    for tH in to_destroy {
        transform_destroy(tH)
    }
}
