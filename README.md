# MoonHug Game Engine Editor
![](readme_files/Logo1.png)

# Generic game engine editor inspired by Unity Editor

## State
Vertical Slice Experimental.
</br>Project has only started, there are frequent API changes, bugs, non-implemented features.
</br>Good moment to add contribution and influence how Editor shapes up.

## Goals
- highly and easily extensible level editor
- allow differently skilled people combine resources together into interactive elements

## Key Ideas
- Editor should be user-friendly
  - easier for users familiar with Unity Editor, for this it should provide similar features when possible but not limited to them
- Editor should provide convenient access to editing assets and/or redirect into external apps

### UX Features
- Editor UX happens through features
  - Each feature provides specific UX solution with optional extensibility

- On top level UX features are represented by window views

For more details see [Contribution](docs/Contribution.md)

## Introduction video
[![](http://img.youtube.com/vi/TQLF-db3Jqs/0.jpg)](https://www.youtube.com/watch?v=TQLF-db3Jqs)

## Updates video
[![](http://img.youtube.com/vi/MEHnLMaGiEo/0.jpg)](https://www.youtube.com/watch?v=MEHnLMaGiEo)

## Contribution
- [Contribution](docs/Contribution.md)

## Community
- [Discord](https://discord.gg/HTpBmhESwW)

## Build/run/workflow stages
- PrebuildStage - generates code for other stages
- DevStage - modifying app and editor code
- AuthoringStage - using running editor to configure assets
- BuildStage - converting app code & resources into shippable Build product
- RuntimeStage - app running

## Folder structure
- prebuild - generator folder
  - separate program that runs even before anything compiles
- editor, *_editor - editor folders
  - editor is top level package with dependencies on everything else
- app folder - game code
  - app package should not have any editor dependencies
- engine - core dependency for app and editor
- builds folder - build results with runnable application
- external - external dependencies folder
- library - derived-data cache (Unity's Library model, see [library](#library)). Safe to delete, rebuilt on the next run

## Dependencies
- odin-imgui - for Editor's interface rendering
- SDL3 + SDL_GPU (`brew install sdl3`) - window, input, GPU rendering (see [SDL3 Renderer](docs/SDL3Renderer.md))
  - one-time: `make -C "$(odin root)/vendor/stb/src"` - builds vendored stb (image decoding)
  - one-time: `make -C "$(odin root)/vendor/cgltf/src"` - builds vendored cgltf (glTF mesh import)
  - one-time: `sh "$(odin root)/vendor/box2d/build_box2d.sh"` - builds vendored box2d (physics2d package; needs cmake, WASM step may warn — harmless)
  - one-time: `cd "$(odin root)/vendor/box3d/src" && sh build.sh` - builds vendored box3d (physics3d package; bundled source, clang only)
  - optional, only to AUTHOR shaders (engine built-ins or .glsl assets): `brew install shaderc spirv-cross`

## library

Everything under `library/` is derived data — never a source of truth, safe to delete, rebuilt from assets + metas on the next run (Unity's Library contract).

- `library/artifacts/<xx>/<key>.bin` - import artifacts, **content-addressed**: the 128-bit key hashes every input that shapes the importer's output — source bytes, import settings, the importer's version constant, the artifact format version. Invalidation is automatic (any changed input is a different key), toggling a setting back is a cache hit on the old artifact instead of a re-import, and keys are machine-independent (a shared team cache stays possible). `<xx>` is the key's first two hex chars (Unity's fan-out layout)
- `library/artifact_db.json` - the index: guid → current artifact key + source file stamp + settings hash, so an unchanged file costs one stat per scan, never a rehash
- `library/thumbnails/<xx>/<guid>.thumb` - project view thumbnails (raw RGBA + a stamp header), guid-keyed so a changed asset overwrites its entry in place. Written asynchronously after generation (fence-polled GPU readback, no sync stalls), loaded instead of re-rendering on the next session. Deleted assets' entries are pruned at editor startup
- `library/state_cache/` - editor session state (the Play button's live-scene snapshot)
- garbage collection runs with the import pass: artifact files no index entry references are deleted
- importers carry a version constant (`_importer_version`) — bump it when an importer's output changes and exactly its artifacts re-import, nothing else

## Features
- menu bar - customizable via @(menu_item=...) on proc

- scene view overlays - Unity-style dockable overlays (drag the grip to dock to view edges or float), extensible via @(scene_overlay={id="...", order=0}) on a proc that draws IMGUI; item tooltips end with the overlay id and order

- Project Settings window (Edit ▸ Project Settings…) - Unity-style section list + inspector pane, extensible via @(project_settings={name="Tab"}) on a package-level settings struct var; values persist to ProjectSettings/*.json, read by editor and game, edits undoable (see [Plugins](docs/Plugins.md))

- union serialization (#no_nil unions only)

- [Asset Pipeline](docs/AssetPipeline.md) - asset importer/loader
- [Components](docs/Components.md) - component data layer: pools, handles, iteration contract
- [Scenes](docs/Scenes.md)
- [Tweens](docs/Tweens.md)
- [Reference Handles](docs/ReferenceHandles.md)
- [Object Picker](docs/ObjectPicker.md) - Unity-style reference picker: Scene/Project tabs, search, ping, project picks filtered by root component or file extension
- [SDL3 Renderer](docs/SDL3Renderer.md) - SDL3 + SDL_GPU rendering (Metal-native), per-camera render commands, scene view picking + selection outline + move/rotate/scale gizmos
- [Meshes](docs/Meshes.md) - glTF import with per-material submeshes, MeshFilter/MeshRenderer components
- [Materials](docs/Materials.md) - Material assets (built-in unlit/lit shaders + texture/color) on MeshRenderer AND SpriteRenderer, custom .glsl shaders with hot reload + property blocks + multi-texture rows, PBR/specular sample shaders (camera position + world position available to fragment shaders), directional/point/spot Light components (up to 8 per pass), live-editing inspector
- [SpriteRenderer](docs/SpriteRenderer.md)
- [Unity Conveniences](docs/UnityConveniences.md)
- [Multiselection](docs/Multiselection.md) - cmd/shift selection in hierarchy, scene view and project; rubber-band box select; gizmo moves/rotates/scales the whole selection (Pivot/Center toggle); set-wide delete/duplicate/toggle-active as one undo step; inspector shows the active item (no multiedit yet)
- [Crash Journal](docs/CrashJournal.md) - signal-safe crash log with a symbolized stack and a breadcrumb of what the editor was doing (`logs/crash_<pid>.log`)
- [MCP Bridge](docs/McpBridge.md) - agent access to the running editor (scene dumps, menu invocation) over MCP, zero external dependencies
- [Undo](docs/Undo.md) - editor undo feature
- [Simulate](docs/Simulate.md) - play the open scene inside the editor with everything still inspectable: Simulate/Pause/Step controls, snapshot+restore on stop, sim-host dropdown picking which game's update code runs. Separate from the Play button, which builds and launches the game as its own process

### Views
  - inspector view - edit selected object in scene
  - project inspector - preview and edit selected asset in project
  - hierarchy view - shows scene tree
  - project view - left pane is folder tree, right pane is selected folder contents. Unity-style zoom slider bottom right — minimum is the list, above it a thumbnail grid (image/material/scene previews rendered on demand, budgeted per frame, cached by guid + file stamp, persisted under library/thumbnails across sessions)
  - console view
  - scene view - view and edit scene contents

- custom drawers
  - custom property drawers - via @(property_drawer=...) on proc
  - custom decorator drawers - via field tags `decor:procName(arg=value)`

- inspector buttons (invoke a proc from the inspector, one undo step)
  - component-level via @(inspector_button={label="...", row=0, weight=1, show_in_array=true}) on a `(^Component)` proc
  - field-anchored via field tag `decor:button(proc_name, label="", row=0, weight=1)`
    - proc is `()`, `(^Component)` or `(^Component, ^Field)`
    - same `row` shares one line, widths split by `weight`
  - higher row renders higher on screen — rows >= 0 stack above the field/fields, rows < 0 below

### Components
- Component menu - via @(component={menu="menu/path"}) on struct
  - adds to Component menu bar and Add Component button popup
  - if no menu path specified, type name is used

## TODO
- mesh tangents + linear color pipeline (pbr.glsl works around both in-shader)

- png - Texture2D with N Sprites

- transform:
  - use bit set + procs, instead of direct bool change
  - consider making transform regular component (required or optional), node will hold all components

- improve default types inspector UX

- project file ops: Windows trash/reveal (darwin-only today, see project_os_stub.odin)

- hierarchy fix copy/paste/duplicate bugs

- physics2d follow-ups:
  - PhysicsLayerCollision2D settings asset
  - PhysicsMaterial2D asset
  - effectors/polygon colliders

- physics3d follow-ups:
  - PhysicsLayerCollision settings asset
  - PhysicsMaterial asset
  - mesh/compound colliders
  - explicit mass

- bulk entity tier for mass simulation (100k-scale sprite battles): SoA arrays + fixed-tick sim + GPU instancing, see [Components](docs/Components.md) "Two data regimes"

- come up with more TODO and Considered features

- clear clipboard completely on each copy call

- keep improving memory guide
  - must be explained simply as if for someone new to memory handling

- Node graph editor for different use-cases
  - VFX graph

- undo follow-ups: asset doc Revert button, import settings onto the asset doc model
- multiselection follow-ups: multiedit, multi-path drag-drop

### Considered Features

- Task tracking with backlog, todo, etc.

- some kind of type defaults fill only what json serialized data doesn't cover

- doc generation

- multiple views(windows) of same type support, with lock toggle
- popup manager
  - show serialized or in-memory asset inspector as popup with custom title
    - override property drawer for custom popup look

- convert tween_free to cleanup_T

- generalized serialization of Owned and Ref
- generic Handle resolve and reset Handle when resolve fails

- ability to switch Value/Ref field in inspector where valid

- Dirty flags for modified data

- Convert resource into usable format at buildStage or runtimeStage

- consider SceneFile to hold serialize blobs instead of real types

- bug:[WON'T FIX] terminal-launched editor doesn't gain keyboard focus on some startups (macOS cooperative activation denies non-Launch-Services processes; refocus app to repair). Real fix: .app bundle + `open` in run scripts, icon via Info.plist (drops set_dock_icon)
