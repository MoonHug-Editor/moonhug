---
title: "Scenes"
description: "How scenes are stored on disk, serialized and deserialized, loaded in different modes, and shown in the editor"
weight: 20
tags: ["scenes", "serialization", "engine"]
path: engine/concepts/scenes
---

**What lives on disk:**
```
assets/
  main.scene          ← serialized JSON, committed to git
```

## Core concepts


```
World          — owner of all runtime pools (transforms, sprite_renderers, scripts, …)
SceneManager   — holds up to MAX_SCENES loaded scenes at once
Scene          — runtime scene: generation counter, root Ref, breadcrumb + NS metadata
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
- `Local_ID` is file-scoped; every transform and component gets one. Authored
  lids are minted randomly in `[1, 2^52)` via
  `scene_new_lid` — random identity lets parallel branches add objects to the
  same scene and merge without collisions. Bit 52 tags composed instance lids
  (`nested_lid_compose`), and all lids stay below 2^53 so they survive
  f64/json round-trips exactly.

## SceneFile

`SceneFile` is the on-disk representation. It contains flat arrays of plain structs — no pointers, no handles:

### Serialization
```odin
SceneFile :: struct {
    root:          Local_ID,
    transforms:    [dynamic]Transform,
    nested_scenes: [dynamic]NestedScene,
    breadcrumbs:   [dynamic]Breadcrumb,
    components:    [dynamic]json.Value, // guid-tagged records, every component type
}
```

Saving walks the transform tree starting from `Scene.root`, collecting every transform and its components into SceneFile's flat arrays. Handles are stripped; only `local_id` fields remain.

```odin
scene_save :: proc(s: ^Scene, path: string) -> bool {
    sf := SceneFile{}
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

// places a copy of the scene under `parent`, fully unpacked: no prefab link
scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle, s: ^Scene) -> Transform_Handle
```

`scene_load` handles the file → SceneFile → Scene pipeline, and `scene_load_async` is the same load over several frames (see "Loading over frames"):

```odin
scene_load       :: proc(path: string, additive := false) -> ^Scene
scene_load_async :: proc(path: string, additive := false, activate := true) -> Scene_Load_Handle
```

The manager stores up to `MAX_SCENES = 100` scenes in a fixed array. `active_scene` is a `Scene_ID` (i16) index into that array.

## Loading over frames

`scene_load_async` loads a scene over several frames, so a running game keeps its frame rate and can show a loading screen.

```odin
h := engine.scene_load_async("assets/level2.scene")   // or additive = true
// each frame:
bar := engine.scene_load_progress(h)                   // 0 to 1
if engine.scene_load_done(h) {
    level := engine.scene_load_scene(h)                // nil when the load failed
}
```

The stages, in order:

- Read and parse the scene file on a worker thread.
- List the assets the scene references. Each nested prefab file is parsed on a worker thread and its references are listed too. A prefab's list is kept until an asset changes, so each prefab parses once per process.
- Load those assets: textures, meshes, materials with their shader and textures, audio clips, animation clips, fonts. Each asset's file is read and decoded on a worker thread, all at the same time. The load waits until every one is in its cache.
- Create the objects and awake them. A load that is not additive unloads the loaded scenes right before this stage, so they run until then.

Rules:

- `frame_tick` runs the loads at the start of each frame for `SCENE_LOAD_FRAME_BUDGET_MS` (4 ms). On the main thread that is the walk of the parsed file for its asset references, the short last part of each asset's load (a GPU upload), and the creation of the objects.
- One piece of work always finishes: one reference walk, one asset's last part, the creation of the objects. A large scene can take more than the budget in the frame that creates its objects.
- The load waits for the asset jobs started up to the end of its asset stage. A job that starts later, such as another load's, does not hold it back.
- `activate = false` stops the load before the last stage, with the assets loaded. `scene_load_ready(h)` is true then, and `scene_load_activate(h)` lets it finish. Use it for "press a key to continue" or to finish a fade first.
- Outside a running game no frame runs the loads, so the call loads the whole scene before it returns.
- A load ends with the game: Stop in the editor drops the loads in progress.
- `scene_load` is the same load in one call. The editor and the boot scene use it. In a game it loads the scene's assets in the same call. In the editor each asset loads on first use.

What is not loaded ahead:

- An asset no component of the scene names, such as one a script picks by guid.
- The assets of a scene that a field names (a list of levels, a prefab a script spawns). Only nested prefabs are opened.
- `engine.asset_preload(ref)` loads either by hand. For a prefab it loads every asset the prefab references.

An asset type joins the preload with `@(asset_preload={ext="mp3,wav,ogg"})` on a proc named `asset_preload_<name>` that takes the `PPtr` and starts the asset's load (`plugins/engine/asset_preload.odin`). Several procs can name one extension: a model file holds mesh parts and clips, the engine's proc loads a part id and the animation plugin's proc loads a clip id.

### Asset jobs

One job loads one asset in three parts (`plugins/engine/asset_jobs.odin`):

- **Begin**, main thread: the asset type finds the file and calls `asset_job_start(ref, path, finish, work)`.
- **Work**, worker thread: the job system reads the file into `job.data`, then the type's `work` proc decodes it into plain memory.
- **Finish**, main thread: the type's `finish` proc uploads to the GPU and puts the result in its cache. `frame_tick` runs the finish procs of the jobs that are done.

| Asset | Worker thread | Main thread |
|---|---|---|
| Texture | file read, image decode | GPU upload |
| Mesh | file read | GPU buffers |
| Audio clip | file read and decode | cache |
| Font | file read, parse | atlas upload |
| Animation clip | file read | parse |
| Scene file, nested prefab | file read, parse | reference walk |
| Material, shader | | all of it |

Rules for a `work` proc:

- It reads `job.data` and `job.path`, and writes `job.user` and `job.failed`.
- It allocates with `runtime.default_allocator()`, with an allocator the start passed in `job.user` that is safe on any thread, or with `context.temp_allocator` for scratch memory. The scene file parse gets the frame's allocator this way, since the scene takes parts of the parsed file.
- It touches no cache, no asset database, no GPU and no engine global, and it does not log. `finish` reports a failed job.

A loader starts with `asset_job_wait(ref, finish)`. So a draw or a `scene_load` that needs an asset while its job runs waits for that one job, and nothing sees a half-loaded asset. An asset that changes on disk ends its jobs before the caches drop it.

Jobs are numbered in the order they start. `asset_jobs_mark()` gives the number of the last one, and `asset_jobs_pending(until)` and `asset_jobs_wait_all(until)` count only the jobs started up to that mark.

At engine shutdown every job is discarded: `job.discard` is set, and `finish` only frees what `work` made.

An animation clip is parsed on the main thread because reading a reference uses engine state. A scene file parse reads references too, through a hook whose state is per thread: a parse on a worker binds nothing, the same as a parse on the main thread outside a scene build. A material is a small file. A shader's cost is the GPU pipeline, which the main thread makes.

## Scene lifetime

```
scene_new()       → allocates, sets generation = 1
scene_destroy()   → destroys root transform tree, frees memory, sets generation = 0
scene_is_valid()  → generation > 0
scene_unload()    → finds scene in manager, calls scene_destroy, clears slot
```

Generation is used as a validity sentinel — a zeroed generation means the scene has been destroyed.

## UX

- scene files can be selected in Project window
- hierarchy shows SceneManager's loaded scenes
- Scene window shows objects of loaded scenes in 3D space
- inspector shows selected transform and its components

### Scene Window UX
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
