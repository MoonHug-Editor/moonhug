# Scenes

**What lives on disk:**
```
assets/
  main.scene          ← serialized JSON, committed to git
```

## Core concepts


```
World          — owner of all runtime pools (transforms, sprite_renderers, scripts, …)
SceneManager   — holds up to MAX_SCENES loaded scenes at once
Scene          — runtime scene: generation counter, root Ref, next_local_id counter
SceneFile      — plain-struct snapshot of a transform tree, used for save/load
```

A `Scene` is just a thin header. All entity data lives in the `World` pools. The scene tracks its root transform via a `Ref` (stable `PPtr` + runtime `Handle`).

## Reference types

```odin
PPtr   :: struct { guid: Asset_GUID, local_id: Local_ID }   // stable, serialized
Handle :: struct { index: u32, generation: u32 }            // runtime only
Ref    :: struct { pptr: PPtr, handle: Handle }             // can reference project and local items
Owned  :: struct { local_id: Local_ID, handle: Handle, type_key: Type_Key } // local reference destroyed with owner
```

- `PPtr` survives save/load — it is what goes to disk.
- `Handle` is resolved at load time and never serialized.
- `Local_ID` is file-scoped; for scene file every transform and component gets one

## SceneFile

`SceneFile` is the on-disk representation. It contains flat arrays of plain structs — no pointers, no handles:

### Serialization
```odin
SceneFile :: struct {
    root:             Local_ID,
    next_local_id:    Local_ID,
    transforms:       [dynamic]Transform,
    sprite_renderers: [dynamic]SpriteRenderer,
    scripts:          [dynamic]Script,
}
```

Saving walks the transform tree starting from `Scene.root`, collecting every transform and its components into SceneFile's flat arrays. Handles are stripped; only `local_id` fields remain.

```odin
scene_save :: proc(s: ^Scene, path: string) -> bool {
    sf := SceneFile{}
    sf.next_local_id = s.next_local_id
    _collect_transform_tree(w, Transform_Handle(s.root.handle), &sf)
    data, _ := json.marshal(sf, opts)   // pretty JSON
    os.write_entire_file(path, data)
    s.path = strings.clone(path)
}
```

### Deserialization
JSON unmarshal into SceneFile struct

```odin
scene_file_load :: proc(filepath: string) -> (SceneFile, bool) {
    data, _ := os.read_entire_file(filepath)
    json.unmarshal(data, &sf)
    return sf, true
}
```

## Scene Load Modes

```odin
// unloads all existing scenes first
scene_load_single   :: proc(sf: ^SceneFile) -> ^Scene

// adds alongside existing scenes
scene_load_additive :: proc(sf: ^SceneFile) -> ^Scene 

// behaves like Unity's GameObject.Instantiate (fully unpacked prefab)
scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle, s: ^Scene) -> Transform_Handle
```

Convenience path wrappers handle the file → SceneFile → Scene pipeline:

```odin
scene_load_path          :: proc(path: string) -> ^Scene  // single
scene_load_additive_path :: proc(path: string) -> ^Scene  // additive
```

The manager stores up to `MAX_SCENES = 100` scenes in a fixed array. `active_scene` is a `Scene_ID` (i16) index into that array.

## Scene lifetime

```
scene_new()       → allocates, sets generation = 1
scene_destroy()   → destroys root transform tree, frees memory, sets generation = 0
scene_is_valid()  → generation > 0
scene_unload()    → finds scene in manager, calls scene_destroy, clears slot
```

Generation is used as a validity sentinel — a zeroed generation means the scene has been destroyed.

## UX

- scene files can be selected in project view
- hierarchy shows SceneManager's loaded scenes
- scene view shows objects of loaded scenes in 3D space
- inspector shows selected transform and its components

### Scene View UX
The editor renders the active scene into an offscreen `RenderTexture2D` and displays it as an ImGui image. Camera is an orbit/flythrough hybrid:

| Input | Action |
|---|---|
| RMB drag | Flythrough look |
| W/A/S/D/Q/E (while RMB) | Flythrough move (Shift = 3× speed) |
| Alt + LMB drag | Orbit |
| Alt + RMB drag | Zoom (drag) |
| MMB drag | Pan |
| Scroll wheel | Zoom |

Camera state is stored as `(yaw, pitch, dist, target)` and converted to a `Camera3D` each frame via `update_scene_camera`.
