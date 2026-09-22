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

## License
zlib — see [LICENSE](LICENSE). Games built with MoonHug carry no notice
obligation from MoonHug itself; bundled third-party components and what they
require are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Contributions are accepted under the same license
(see [Contribution](docs/Contribution.md)).

## Building

Install [Odin](https://odin-lang.org/docs/install/) and SDL3 (`brew install sdl3`), then, in a fresh clone:

```sh
odin run tools/mh -- setup
```
```sh
odin run tools/mh -- run
```

`make setup` and `make run` do the same when make is installed. Every command,
dependency and build step: [Install, Build and Run](docs/InstallBuildAndRun.md).

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
  - engine_editor is the engine's editor half — subpackages pairing with engine ones (engine_editor/asset_pipeline is the write side of engine/asset_pipeline.odin: importers, import drivers, AssetDB scanning, meta writing) — never linked into game binaries (the app runs the catalog pipeline only)
- app folder - game code
  - app package should not have any editor dependencies
- engine - core dependency for app and editor
- builds folder - build results with runnable application
- external - external dependencies folder
- library - derived-data cache (Unity's Library model, see [library](#library)). Safe to delete, rebuilt on the next run
- ProjectSettings - settings about the PROJECT, committed: `mcp.json` and one `<slug>.json` per @(project_settings) tab
- UserSettings - per-developer editor state, never committed (Unity's UserSettings): window geometry, open scenes and windows, panel visibility, theme, grid and snap, selected run config. Safe to delete, the editor writes defaults on the next run

## Dependencies
- odin-imgui - for Editor's interface rendering
- SDL3 + SDL_GPU (`brew install sdl3`) - window, input, GPU rendering (see [SDL3 Renderer](docs/SDL3Renderer.md))
- vendored C libraries Odin ships as source (stb, cgltf, box2d, box3d), all built by `mh setup`

Full list and what needs them: [Install, Build and Run](docs/InstallBuildAndRun.md#dependencies).

## library

Everything under `library/` is derived data — never a source of truth, safe to delete, rebuilt from assets + metas on the next run (Unity's Library contract).

- `library/artifacts/<xx>/<key>.bin` - import artifacts, **content-addressed**: the 128-bit key hashes every input that shapes the importer's output — source bytes, import settings, the importer's version constant, the artifact format version. Invalidation is automatic (any changed input is a different key), toggling a setting back is a cache hit on the old artifact instead of a re-import, and keys are machine-independent (a shared team cache stays possible). `<xx>` is the key's first two hex chars (Unity's fan-out layout)
- `library/artifact_db.json` - the index: guid → current artifact key + source file stamp + settings hash, so an unchanged file costs one stat per scan, never a rehash
- `library/thumbnails/<xx>/<guid>.thumb` - project view thumbnails (raw RGBA + a stamp header), guid-keyed so a changed asset overwrites its entry in place. Written asynchronously after generation (fence-polled GPU readback, no sync stalls), loaded instead of re-rendering on the next session. Deleted assets' entries are pruned at editor startup
- `library/state_cache/` - editor session state (the Play button's live-scene snapshot)
- garbage collection runs with the import pass: artifact files no index entry references are deleted
- importers carry a version constant (`_importer_version`) — bump it when an importer's output changes and exactly its artifacts re-import, nothing else

## Features
- menu bar - customizable via @(menu_item=...). Attribute on a proc it is an action, on a bool variable it is a toggle. `checked=<proc>` draws a tick from computed state, can be used for a radio group. `enabled=<proc>` greys an item out

- view tab bar and menu - every dock node's tab bar carries the visible view's toolbar items, then a ⋮ menu. Any package adds to either: @(view_tab_bar={view="Animation", order=0}) on a proc draws a widget, @(view_menu={view="Animation", label="..."}) on a proc is an action and on a bool variable a toggle, with `checked=`/`enabled=` like menu_item.

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
- [Text](docs/Text.md) - TextMeshPro-shaped text plugin for the canvas tree: font files import into a signed-distance-field atlas, an SDF material shader gives outline, underlay shadow, dilation and softness, sharp at any size, backend-neutral layout with a swappable glyph source
- [Handles](docs/Handles.md) - scene-view interaction layer for editor and package editors: immediate-mode drag handles on a plane, overlay drawing, one drag = one undo step, picking providers
- [GUI](docs/Gui.md) - canvas tree in the engine (Canvas, RectTransform anchors/pivot layout, CanvasRenderer, CanvasScaler, rect walk with layout providers), mhgui plugin package for the graphics (Image, sprite or solid color), LayoutGroup (row/column/grid), the render collector and the rect tool on editor/handles
- [Unity Conveniences](docs/UnityConveniences.md)
- [Multiselection](docs/Multiselection.md) - cmd/shift selection in hierarchy, scene view and project; rubber-band box select; gizmo moves/rotates/scales the whole selection (Pivot/Center toggle); set-wide delete/duplicate/toggle-active as one undo step; multiedit of shared components with Unity's mixed-value indicators
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
  - scene view - view and edit scene contents. Perspective/orthographic toggle and axis views from the scene gizmo (top-right), a 2D button for a fixed front view with pan-only navigation, F frames the selection (UI rects and canvases included)

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
- skinned mesh runs on the CPU: `SkinnedMeshRenderer` rebuilds the bind-pose
  vertices through the skin matrices every frame and uploads them. GPU skinning
  — a bone matrix buffer plus a vertex shader variant — is the drop-in
  replacement that makes many characters on screen affordable

- mesh tangents + linear color pipeline (pbr.glsl works around both in-shader)

- sprite atlas (batching): a .spriteatlas asset packs slices from many textures into one atlas artifact, sprite_quad redirects texture + uvs through the atlas mapping — renderers and scenes untouched. PPtr sprite references are the mapping key

- spline package: a path through space, the spatial counterpart to the engine's scalar `Curve`
  - a Spline component holding control points, edited in the scene view through the handles layer
  - sampling by parameter and by arc length
  - consumers decide what a path means: move a transform along it, aim a camera, place objects at intervals
  - first consumer: a sequencer track that drives a transform along a spline

- transform:
  - use bit set + procs, instead of direct bool change
  - consider making transform regular component (required or optional), node will hold all components

- handles follow-ups (see [Handles](docs/Handles.md)) - missing composites, and the wiring gizmo.odin kept to itself
  - axis-constrained slider handle - drag along one direction, not just on a plane
  - snapping - `snap_settings` and the Ctrl-modifier XOR live in gizmo.odin, so a package-authored handle ignores the user's snap setting
  - bezier/curve drawing
  - bounds handles (box, sphere, capsule)
  - port gizmo.odin onto handles, leaving one input system. Its own job
  - box select through pick providers - click picking consults them, box select does not

- gizmo drawing - `gfx.draw_line` is the only primitive, so `_draw_cone`, `_draw_cube`, the collider drawers and handles each rebuild the same shapes. ALINE (Unity asset) is the reference for the surface, but DESIGN THE API FIRST
  - decide what a draw call carries before adding shapes: colour and space as scopes or as arguments, who owns depth-test choice, whether a shape can outlive the frame
  - shape library over `draw_line` - arc, circle per plane, wire box, sphere, capsule, cylinder, cone, arrow, cross, grid, polyline, bezier
  - local space, so a component draws in its own coordinates
  - duration - a shape that stays for N seconds, needs a retained buffer the pass drains
  - line width - the one item with real renderer cost, since lines become quads
  - solid shapes and labels reachable from a gizmo proc, not only from handles
  - done when `gizmo.odin`, the collider drawers and handles all delete their private shape code

- dynamic menu items - every item is registered at init, so nothing can compute its item set at draw time. Recent Scenes, run configs, the inspector's "Apply to Prefab 'X'" list
  - one new kind holding a `proc()` that draws its own items into the open menu
  - `collect_invokable_paths` feeds MCP `list_menus` / `invoke_menu` and `_process_menu_shortcuts` walks the tree for shortcuts, so a dynamic item can be neither listed, invoked by path, nor bound to a key
  - keep it the escape hatch, not the general form: Recent Scenes is the right user, "Save Scene" is not

- improve default types inspector UX

- draw materials below components in inspector

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

- modularize packages
  - core (TypeKey, Ref, Handle, etc.)
  - tweens
  - etc.

- come up with more TODO and Considered features

- clear clipboard completely on each copy call

- keep improving memory guide
  - must be explained simply as if for someone new to memory handling

- Node graph editor for different use-cases
  - VFX graph

- undo follow-ups: asset doc Revert button, import settings onto the asset doc model
- multiselection follow-ups: multi-path drag-drop, multiedit for prefab-instance selections

### Considered Features

- preview section in hierarchy inspector (project inspector has one)

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
