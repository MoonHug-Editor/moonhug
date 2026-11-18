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

### Unions

A union field saves its active variant tagged with the variant's type (`libs/serialization/union_serialization.odin`):

```json
{ "__type_guid": "3d9b41f7-...", "clip": "...", "speed": 1 }
{ "__type_guid": "6f0e1c52-...", "__value": 1 }
{ "__type": "[3]f32", "__value": [0, 2.5, 0] }
```

- A struct variant has its fields next to its guid.
- A declared variant that is not a struct, such as an enum, has its guid and its `__value`.
- A literal type, one the language spells such as `f32`, `bool` or `[3]f32`, has no declaration to carry a guid. It is tagged with its text in `__type`, which the language fixes, and its `__value`.
- `serialization.register_union_type(T)` makes a union save this way. `union_gen` calls it for every hand-written union whose variants all carry `@(typ_guid)`, and a generator that emits a union calls it itself. Every variant must have a guid or be a literal type, which is checked when the serializers are installed.
- A variant tag no installed plugin knows is dangling data: the load fails for that value and does not crash.

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

## Finding objects from code

- `transform_find(parent, "Arm/Hand")` returns the object at a path of names under `parent`. Each name is a direct child of the one before it. An empty path is `parent` itself.
- `transform_find_in_children(root, "Hand")` returns the first object of that name under `root` at any depth, `root` included, depth first with children in order.
- Both return the handle and whether it was found. Two children of one name: the first in child order wins.
- `transform_hierarchy_path(object)` gives the path the other way, from the scene root down to the object.
- `sm_find_objects_of_type(key)` lists every object or component of a type in the loaded scenes.

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

### Scene camera preferences

The Camera overlay (the camera button) opens the Scene window's camera preferences: the perspective view's field of view, the fly speed and the look sensitivity, with Reset for the defaults. They hold for every Scene window and every scene, and are saved with the editor's settings.

- The wheel changes the fly speed while flying. The new speed shows at the bottom of the view for a moment, and is the value the popup shows.

### Creating at a point

An object made from the Scene window's right-click menu lands where the menu was opened: on the surface under the pointer, or on the grid plane over empty space, as a dropped asset does. A child made that way is at that point too, under its parent. The same items in the menu bar and in the Hierarchy create at the origin of their parent.

### Pick locks

The lock at the right end of a Hierarchy row locks the object against picking: the Scene window passes it and everything under it over, for clicks and for box selection. A floor or a backdrop stops catching the clicks meant for what stands on it.

- A locked row shows a lock, a row under a locked object a dim one, and the hovered row an open lock to click.
- A locked object still selects from the Hierarchy, and its gizmo works as before.
- The locks are a developer's own, kept per scene in the user settings. A scene never saved keeps none.
- An object inside a prefab instance is locked by its prefab, so the lock shows on every instance of that prefab.

### Scale link

The link button on the Transform's Scale row keeps an object's proportions: with it on, a change to one axis scales the other two by the same ratio. It holds for every object and is saved with the user settings.

- An axis that was 0 has no ratio, so the other two take the new value.
- A value set on two or three axes at once (a paste, a reset) is left as it is.

### Render layers to children

After the Inspector's Render Layers row changes on an object with children, a dialog asks whether the children take the same layers.

- Yes writes the object's layers to every object under it, at any depth. The writes are part of the undo step of the change, so one undo takes back both.
- No leaves the children as they are.
- The question comes when the row's list closes, once for all the changes made while it was open. It does not come when every object under it has those layers already.
- With several objects selected, the question covers the children of each.
- On a prefab instance each child written records an override.
- From code, `scene_windows.render_layers_apply_to_children(parents)` does the same without the question.

### Nudge

In an orthographic Scene view (2D mode included), the arrow keys move the selection one step along the screen's axes: Left and Right along the view's right axis, Up and Down along its up axis. In a perspective view the keys move nothing.

- A world object's step is the snap move step (the Snap popup's mode: a grid cell, a grid subdivision or a free value). The move is by that step, the object is not aligned to the grid.
- A UI element's step is one canvas unit.
- Shift moves ten steps.
- A held key repeats, and one hold is one undo step. Every selected top-level object moves by the same offset.
- On a prefab instance the move records a position override, as a drag of the move handle does.
- The keys are the commands `Scene/Nudge Left`, `Right`, `Up` and `Down`, bound in the Scene window's keymap.

### Measure tool

The Measure tool (M, the ruler at the end of the Tools overlay) measures the distance between two points: drag from one to the other. The measurement stays until the next drag, a click or another tool.

- An end lands where the pointer meets an object, on a UI canvas, or on the grid over empty space. While snapping is on (the Snap popup's toggle, flipped while the snap modifier is held, Ctrl or Cmd on macOS), an end off a canvas snaps to the move step.
- The line between the ends shows the distance at its middle, in world units, and the part along each axis under it. Its legs along X, Y and Z are drawn in the axis colors.
- With both ends on one UI canvas the distance is in the canvas's pixels, and the ends snap to whole pixels. An overlay canvas counts in the 2D view only: in 3D it is a rectangle hundreds of units wide at the origin. A world-space canvas, or one in front of a camera, counts in both.
- While the tool is on, a left click or drag never selects. The camera moves as in every tool.
- Code reads the shown measurement with `scene_tools.measure_result()` and its distance with `scene_tools.measure_distance(m)`.

The camera is kept per scene, per developer, in `UserSettings/scene_cameras.json`, until the scene leaves the project: a scene opens where the Scene window last looked at it, after another scene and after a restart, in 2D or 3D as it was left. A scene seen for the first time keeps the view as it is. With several Scene windows, each takes the saved camera when the active scene changes, and the last one used keeps it saved.
