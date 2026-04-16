package engine

UserContext :: struct {
    world         : ^World,
    scene_manager : SceneManager,
    is_playmode : bool,
    inspector     : InspectorState,
}

InspectorState :: struct {
    readonly_depth: int,
    nested_host_tH: Transform_Handle,
}

ctx_get :: proc() -> ^UserContext {
    return cast(^UserContext)context.user_ptr
}

ctx_world :: proc() -> ^World {
    return ctx_get().world
}

ctx_scene_manager :: proc() -> ^SceneManager {
    return &ctx_get().scene_manager
}

inspector_push_readonly :: proc() {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.readonly_depth += 1
}

inspector_pop_readonly :: proc() {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.readonly_depth -= 1
    if uc.inspector.readonly_depth < 0 do uc.inspector.readonly_depth = 0
}

inspector_is_readonly :: proc() -> bool {
    uc := ctx_get()
    if uc == nil do return false
    return uc.inspector.readonly_depth > 0
}

inspector_set_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    uc := ctx_get()
    if uc == nil do return {}
    prev := uc.inspector.nested_host_tH
    uc.inspector.nested_host_tH = tH
    return prev
}

inspector_get_nested_host :: proc() -> Transform_Handle {
    uc := ctx_get()
    if uc == nil do return {}
    return uc.inspector.nested_host_tH
}
