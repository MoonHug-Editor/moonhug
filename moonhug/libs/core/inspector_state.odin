package core

// Inspector state the editor's packages share without importing each other:
// the read-only depth, the nested-scene host a drawer is editing under, the
// active and inspected selection, and one-slot request mailboxes. A drawer
// posts "select this", "ping that", "open this asset", and the view that owns
// the answer takes the request once per frame. Transform_Handle here is an
// object id, not a scene-tree walk.

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
    // The object the Inspector shows: the active selection, or, while the
    // project holds the selection, the object the Inspector kept. What tool
    // windows (animation, sequencer) follow, so clicking an asset does not
    // take their target away. active_scene_tH stays the live selection, which
    // creation menus parent under.
    inspected_scene_tH:    Transform_Handle,
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
    pending_select_asset:  Asset_GUID,
    // Open request: the project view navigates AND activates the asset
    // (opens scenes, loads .asset into the inspector).
    pending_open_asset:    Asset_GUID,
}

@(private) _inspector: InspectorState

inspector_push_readonly :: proc() {
    _inspector.readonly_depth += 1
}

inspector_pop_readonly :: proc() {
    _inspector.readonly_depth -= 1
    if _inspector.readonly_depth < 0 do _inspector.readonly_depth = 0
}

inspector_is_readonly :: proc() -> bool {
    return _inspector.readonly_depth > 0
}

inspector_set_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    prev := _inspector.nested_host_tH
    _inspector.nested_host_tH = tH
    return prev
}

inspector_get_nested_host :: proc() -> Transform_Handle {
    return _inspector.nested_host_tH
}

inspector_set_nested_local_id :: proc(id: Local_ID) -> Local_ID {
    prev := _inspector.nested_local_id
    _inspector.nested_local_id = id
    return prev
}

inspector_get_nested_local_id :: proc() -> Local_ID {
    return _inspector.nested_local_id
}

// Publishes the scene selection's active transform. The editor root calls
// this once per frame; package editor windows read it.
inspector_set_active_selection :: proc(tH: Transform_Handle) {
    _inspector.active_scene_tH = tH
}

inspector_active_selection :: proc() -> Transform_Handle {
    return _inspector.active_scene_tH
}

inspector_set_inspected_selection :: proc(tH: Transform_Handle) {
    _inspector.inspected_scene_tH = tH
}

inspector_inspected_selection :: proc() -> Transform_Handle {
    return _inspector.inspected_scene_tH
}

// Posts a cross-package "select this transform" request. The editor's
// hierarchy view consumes it via `inspector_take_pending_select` once per
// frame. Calling repeatedly within the same frame keeps the latest request.
inspector_request_select :: proc(tH: Transform_Handle) {
    _inspector.pending_select_tH = tH
}

// Returns and clears the pending selection request. Caller (editor) is
// responsible for applying it to its own selection state.
inspector_take_pending_select :: proc() -> (Transform_Handle, bool) {
    tH := _inspector.pending_select_tH
    if tH == {} do return {}, false
    _inspector.pending_select_tH = {}
    return tH, true
}

// Posts a "ping this transform" request: the hierarchy reveals it and flashes
// its row WITHOUT changing the selection (Unity ping).
inspector_request_ping :: proc(tH: Transform_Handle) {
    _inspector.pending_ping_tH = tH
}

inspector_take_pending_ping :: proc() -> (Transform_Handle, bool) {
    tH := _inspector.pending_ping_tH
    if tH == {} do return {}, false
    _inspector.pending_ping_tH = {}
    return tH, true
}

// Posts a cross-package "select this asset" request: reveal it AND make it the
// project view's active file, without the activation an open would do. Menu
// actions that read `projectViewData.selectedFile` — Extract Assets, Create
// Scene Variant — act on it afterwards.
inspector_request_select_asset :: proc(guid: Asset_GUID) {
    _inspector.pending_select_asset = guid
}

inspector_take_pending_select_asset :: proc() -> (Asset_GUID, bool) {
    guid := _inspector.pending_select_asset
    if guid == (Asset_GUID{}) do return {}, false
    _inspector.pending_select_asset = {}
    return guid, true
}

// Posts a cross-package "ping this asset" request; the project view consumes
// it and navigates to / selects the asset.
inspector_request_ping_asset :: proc(guid: Asset_GUID) {
    _inspector.pending_ping_asset = guid
}

inspector_take_pending_ping_asset :: proc() -> (Asset_GUID, bool) {
    guid := _inspector.pending_ping_asset
    if guid == (Asset_GUID{}) do return {}, false
    _inspector.pending_ping_asset = {}
    return guid, true
}

// Posts an "open this asset" request; the project view navigates to it AND
// activates it (double-click semantics: open scene / load into inspector).
inspector_request_open_asset :: proc(guid: Asset_GUID) {
    _inspector.pending_open_asset = guid
}

inspector_take_pending_open_asset :: proc() -> (Asset_GUID, bool) {
    guid := _inspector.pending_open_asset
    if guid == (Asset_GUID{}) do return {}, false
    _inspector.pending_open_asset = {}
    return guid, true
}
