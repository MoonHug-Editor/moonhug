package engine

UserContext :: struct {
    world         : ^World,
    scene_manager : SceneManager,
    // TRUE IN THE EDITOR BINARY, false in the standalone app. Unity's
    // Application.isEditor: fixed per binary, unaffected by Simulate. Set by each
    // binary's main (and by the test bootstrap, which exercises editor behaviour).
    is_editor : bool,
    // Unity's Application.isPlaying. The app sets it once at startup (true for
    // the process lifetime). The editor's Simulate sets it at Start and clears it
    // at Stop - it stays true while paused, pause being a separate condition.
    // "Is this a simulation?" is not stored anywhere: it is is_playing &&
    // is_editor.
    is_playing : bool,
    inspector     : InspectorState,
    undo          : rawptr,
}

// Unity's Application.isEditor: true in the editor binary, false in a standalone
// build. Constant for the lifetime of the process — entering Simulate does not
// change it.
application_is_editor :: proc() -> bool {
    uc := ctx_get()
    return uc != nil && uc.is_editor
}

// Unity's Application.isPlaying - see the field. This is the one component code
// should ask.
application_is_playing :: proc() -> bool {
    uc := ctx_get()
    return uc != nil && uc.is_playing
}

InspectorState :: struct {
    readonly_depth:        int,
    nested_host_tH:        Transform_Handle,
    nested_local_id:       Local_ID,
    // The scene selection's active transform, published once per frame by
    // the editor root. The READ side of the pending_select_tH channel below:
    // package editor windows (sequencer, animation) target the selection
    // without importing the editor root. {} means nothing selected; readers
    // pool-validate, so a handle that died mid-frame is harmless.
    active_scene_tH:       Transform_Handle,
    // Cross-package selection request: subpackages (e.g. inspector) post a
    // transform here; the editor's hierarchy view picks it up next frame and
    // applies it to its own selection state. {} means "no pending request".
    pending_select_tH:     Transform_Handle,
    // Ping (reveal + highlight flash, does NOT change selection) — the
    // hierarchy view consumes it. {} means "no pending request".
    pending_ping_tH:       Transform_Handle,
    // Same channel shape for assets: the project view navigates to and
    // selects the asset ("ping"). {} means "no pending request".
    pending_ping_asset:    Asset_GUID,
    // Open request: the project view navigates AND activates the asset
    // (opens scenes, loads .asset into the inspector).
    pending_open_asset:    Asset_GUID,
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

inspector_set_nested_local_id :: proc(id: Local_ID) -> Local_ID {
    uc := ctx_get()
    if uc == nil do return 0
    prev := uc.inspector.nested_local_id
    uc.inspector.nested_local_id = id
    return prev
}

inspector_get_nested_local_id :: proc() -> Local_ID {
    uc := ctx_get()
    if uc == nil do return 0
    return uc.inspector.nested_local_id
}

// Publishes the scene selection's active transform. The editor root calls
// this once per frame; package editor windows read it.
inspector_set_active_selection :: proc(tH: Transform_Handle) {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.active_scene_tH = tH
}

inspector_active_selection :: proc() -> Transform_Handle {
    uc := ctx_get()
    if uc == nil do return {}
    return uc.inspector.active_scene_tH
}

// Posts a cross-package "select this transform" request. The editor's
// hierarchy view consumes it via `inspector_take_pending_select` once per
// frame. Calling repeatedly within the same frame keeps the latest request.
inspector_request_select :: proc(tH: Transform_Handle) {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.pending_select_tH = tH
}

// Returns and clears the pending selection request. Caller (editor) is
// responsible for applying it to its own selection state.
inspector_take_pending_select :: proc() -> (Transform_Handle, bool) {
    uc := ctx_get()
    if uc == nil do return {}, false
    tH := uc.inspector.pending_select_tH
    if tH == {} do return {}, false
    uc.inspector.pending_select_tH = {}
    return tH, true
}

// Posts a "ping this transform" request: the hierarchy reveals it and flashes
// its row WITHOUT changing the selection (Unity ping).
inspector_request_ping :: proc(tH: Transform_Handle) {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.pending_ping_tH = tH
}

inspector_take_pending_ping :: proc() -> (Transform_Handle, bool) {
    uc := ctx_get()
    if uc == nil do return {}, false
    tH := uc.inspector.pending_ping_tH
    if tH == {} do return {}, false
    uc.inspector.pending_ping_tH = {}
    return tH, true
}

// Posts a cross-package "ping this asset" request; the project view consumes
// it and navigates to / selects the asset.
inspector_request_ping_asset :: proc(guid: Asset_GUID) {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.pending_ping_asset = guid
}

inspector_take_pending_ping_asset :: proc() -> (Asset_GUID, bool) {
    uc := ctx_get()
    if uc == nil do return {}, false
    guid := uc.inspector.pending_ping_asset
    if guid == (Asset_GUID{}) do return {}, false
    uc.inspector.pending_ping_asset = {}
    return guid, true
}

// Posts an "open this asset" request; the project view navigates to it AND
// activates it (double-click semantics: open scene / load into inspector).
inspector_request_open_asset :: proc(guid: Asset_GUID) {
    uc := ctx_get()
    if uc == nil do return
    uc.inspector.pending_open_asset = guid
}

inspector_take_pending_open_asset :: proc() -> (Asset_GUID, bool) {
    uc := ctx_get()
    if uc == nil do return {}, false
    guid := uc.inspector.pending_open_asset
    if guid == (Asset_GUID{}) do return {}, false
    uc.inspector.pending_open_asset = {}
    return guid, true
}
