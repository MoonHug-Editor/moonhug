# MoonHug Game Engine Editor
![](readme_files/Logo1.png)

# Generic game engine editor inspired by Unity Editor

## State
</br>The editor is a generic shell and the engine is a plugin on it — every feature, the engine included, hooks into the editor through attributes.
</br>Code consists of three parts - host packages (moonhug/host), the editor shell (moonhug/editor) and plugins (plugins/, the engine among them), all other parts serve these three.

> There are still frequent API changes, bugs, non-implemented features.
> </br>Good moment to add contribution and influence how Editor shapes up.

## Installation
To build and run the editor, see [Install, Build and Run](docs/general/InstallBuildAndRun.md).

## Goals
- highly and easily extensible level editor
- allow differently skilled people combine resources together into interactive elements

#### Optional Extra Goal
- extensible editor without any engine code to help visualizing odin packages
  - would remove dependency onto engine codebase
  - can be done in MoonHug Editor or as separate project

### UX Features
- Editor UX happens through features
  - Each feature provides specific UX solution with optional extensibility

- On top level UX features are represented by window views

> - Editor should be user-friendly
>   - easier for users familiar with Unity Editor, for this it should provide similar features when possible but not limited to them
> - Editor should provide convenient access to editing assets and/or redirect into external apps

#### Contribution

For more details see [Contribution](docs/general/Contribution.md)

## Introduction video
[![](http://img.youtube.com/vi/TQLF-db3Jqs/0.jpg)](https://www.youtube.com/watch?v=TQLF-db3Jqs)

## Updates video
[![](http://img.youtube.com/vi/MEHnLMaGiEo/0.jpg)](https://www.youtube.com/watch?v=MEHnLMaGiEo)

## Community
- [Discord](https://discord.gg/HTpBmhESwW)

## License
zlib — see [LICENSE](LICENSE). Games built with MoonHug carry no notice
obligation from MoonHug itself; bundled third-party components and what they
require are listed in [THIRD_PARTY_NOTICES.md](docs/general/THIRD_PARTY_NOTICES.md).
Contributions are accepted under the same license.

## Build/run/workflow stages
- PrebuildStage - generates code for other stages
- DevStage - modifying app and editor code
- AuthoringStage - using running editor to configure assets
- BuildStage - converting app code & resources into shippable Build product
- RuntimeStage - app running

## Dependencies
- odin-imgui - for Editor's interface rendering
- SDL3 + SDL_GPU (`brew install sdl3`) - window, input, GPU rendering (see [SDL3 Renderer](plugins/engine/docs/SDL3Renderer.md))
- vendored C libraries Odin ships as source (stb, cgltf, box2d, box3d), all built by `mh setup`

Full list and what needs them: [Install, Build and Run](docs/general/InstallBuildAndRun.md#dependencies).

## Features
- menu bar - customizable via @(menu_item=...). Attribute on a proc it is an action, on a bool variable it is a toggle. `checked=<proc>` draws a tick from computed state, can be used for a radio group. `enabled=<proc>` greys an item out

- dynamic menus - @(menu_dynamic={path="File/Recent Scenes"}) on a proc makes a submenu whose items the proc draws each frame it is open, for item sets that only exist at runtime. Recent Scenes uses it. Nothing inside one can be listed, invoked by path or bound to a key, so it is the escape hatch and @(menu_item) stays the form.
- clips inside a model - a glTF model's animations play without extraction: the importer bakes them beside the mesh parts, each gets its own guid in the model's meta, and a clip field names one like any `.anim`. Nothing but the model and its meta is committed ([Animation](plugins/animation/docs/AnimationComponent.md)).
- documentation site - `mh docs` builds a static site into builds/docs from docs/general, docs/core and each plugin's own docs/ folder, tagged and read from the file system with no server. docs/reference is generated on every build: one page per attribute listing everything registered through it, and one `odin doc` page per engine and editor package.
- view tab bar and menu - every dock node's tab bar carries the visible view's toolbar items, then a ⋮ menu. Any package adds to either: @(view_tab_bar={view="Animation", order=0}) on a proc draws a widget, @(view_menu={view="Animation", label="..."}) on a proc is an action and on a bool variable a toggle, with `checked=`/`enabled=` like menu_item.

- scene view overlays - Unity-style dockable overlays (drag the grip to dock to view edges or float), extensible via @(scene_overlay={id="...", order=0}) on a proc that draws IMGUI; item tooltips end with the overlay id and order

- Project Settings window (Edit ▸ Project Settings…) - Unity-style section list + inspector pane, extensible via @(project_settings={name="Tab"}) on a package-level settings struct var; values persist to ProjectSettings/*.json, read by editor and game, edits undoable (see [Plugins](docs/core/Plugins.md))

- union serialization (#no_nil unions only)

- [Asset Pipeline](docs/core/AssetPipeline.md) - asset importer/loader
- [Components](plugins/engine/docs/Components.md) - component data layer: pools, handles, iteration contract
- [Scenes](plugins/engine/docs/Scenes.md)
- [Tweens](plugins/tween/docs/Tweens.md)
- [Reference Handles](plugins/engine/docs/ReferenceHandles.md)
- [Object Picker](docs/core/ObjectPicker.md) - Unity-style reference picker: Scene/Project tabs, search, ping, project picks filtered by root component or file extension
- [SDL3 Renderer](plugins/engine/docs/SDL3Renderer.md) - SDL3 + SDL_GPU rendering (Metal-native), per-camera render commands, scene view picking + selection outline + move/rotate/scale gizmos
- [Meshes](plugins/engine/docs/Meshes.md) - glTF import with per-material submeshes, MeshFilter/MeshRenderer components
- [Materials](plugins/engine/docs/Materials.md) - Material assets (built-in unlit/lit shaders + texture/color) on MeshRenderer AND SpriteRenderer, custom .glsl shaders with hot reload + property blocks + multi-texture rows, PBR/specular sample shaders (camera position + world position available to fragment shaders), directional/point/spot Light components (up to 8 per pass), live-editing inspector
- [SpriteRenderer](plugins/sprites/docs/SpriteRenderer.md)
- [Text](plugins/text/docs/Text.md) - TextMeshPro-shaped text plugin for the canvas tree: font files import into a signed-distance-field atlas, an SDF material shader gives outline, underlay shadow, dilation and softness, sharp at any size, backend-neutral layout with a swappable glyph source
- [Handles](docs/core/Handles.md) - scene-view interaction layer for editor and package editors: immediate-mode drag handles on a plane or a line, bounds composites (box, sphere, capsule), snapping, overlay drawing, one drag = one undo step, picking providers
- [GUI](plugins/mhgui/docs/Gui.md) - canvas tree in the engine (Canvas, RectTransform anchors/pivot layout, CanvasRenderer, CanvasScaler, rect walk with layout providers), mhgui plugin package for the graphics (Image, sprite or solid color), LayoutGroup (row/column/grid), the render collector and the rect tool on editor/handles
- [Unity Conveniences](docs/general/UnityConveniences.md)
- [Multiselection](docs/core/Multiselection.md) - cmd/shift selection in hierarchy, scene view and project; rubber-band box select; gizmo moves/rotates/scales the whole selection (Pivot/Center toggle); set-wide delete/duplicate/toggle-active as one undo step; multiedit of shared components with Unity's mixed-value indicators
- [Crash Journal](docs/general/CrashJournal.md) - signal-safe crash log with a symbolized stack and a breadcrumb of what the editor was doing (`logs/crash_<pid>.log`)
- [MCP Bridge](docs/core/McpBridge.md) - agent access to the running editor (scene dumps, menu invocation) over MCP, zero external dependencies
- [Undo](docs/core/Undo.md) - editor undo feature
- [Simulate](docs/core/Simulate.md) - play the open scene inside the editor with everything still inspectable: Simulate/Pause/Step controls, snapshot+restore on stop, sim-host dropdown picking which game's update code runs. Separate from the Play button, which builds and launches the game as its own process

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

- improve default types inspector UX

- project file ops: Windows trash/reveal (darwin-only today, see project_os_stub.odin)

- physics2d follow-ups:
  - PhysicsLayerCollision2D settings asset
  - PhysicsMaterial2D asset
  - effectors/polygon colliders

- physics3d follow-ups:
  - PhysicsLayerCollision settings asset
  - PhysicsMaterial asset
  - mesh/compound colliders
  - explicit mass

- bulk entity tier for mass simulation (100k-scale sprite battles): SoA arrays + fixed-tick sim + GPU instancing, see [Components](plugins/engine/docs/Components.md) "Two data regimes"

- come up with more TODO and Considered features

- clear clipboard completely on each copy call

- keep improving memory guide
  - must be explained simply as if for someone new to memory handling

- Node graph editor for different use-cases
  - VFX graph

- undo follow-ups: import settings onto the asset doc model
- multiselection follow-ups: multi-path drag-drop, multiedit for prefab-instance selections

### Considered Features

- preview section in hierarchy inspector (project inspector has one)

- Task tracking with backlog, todo, etc.


- multiple views(windows) of same type support, with lock toggle
- popup manager
  - show serialized or in-memory asset inspector as popup with custom title
    - override property drawer for custom popup look

- generalized serialization of Owned and Ref
- generic Handle resolve and reset Handle when resolve fails

- ability to switch Value/Ref field in inspector where valid


- Convert resource into usable format at buildStage or runtimeStage

- consider SceneFile to hold serialize blobs instead of real types

- bug:[WON'T FIX] terminal-launched editor doesn't gain keyboard focus on some startups (macOS cooperative activation denies non-Launch-Services processes; refocus app to repair). Real fix: .app bundle + `open` in run scripts, icon via Info.plist (drops set_dock_icon)
