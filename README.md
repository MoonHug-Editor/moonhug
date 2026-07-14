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
- library - cached compiled resources files

## Dependencies
- odin-imgui - for Editor's interface rendering
- SDL3 + SDL_GPU (`brew install sdl3`) - window, input, GPU rendering (see [SDL3 Renderer](docs/SDL3Renderer.md))
  - one-time: `make -C "$(odin root)/vendor/stb/src"` - builds vendored stb (image decoding)
  - one-time: `make -C "$(odin root)/vendor/cgltf/src"` - builds vendored cgltf (glTF mesh import)
  - optional, only to AUTHOR shaders (engine built-ins or .glsl assets): `brew install shaderc spirv-cross`

## Features
- menu bar - customizable via @(menu_item=...) on proc

- scene view toolbars - Unity-style dockable overlays (drag the grip to dock to view edges or float), extensible via @(scene_toolbar={id="...", order=0}) on a proc that draws IMGUI; item tooltips end with the toolbar id and order

- union serialization (#no_nil unions only)

- [Asset Pipeline](docs/AssetPipeline.md) - asset importer/loader
- [Scenes](docs/Scenes.md)
- [Tweens](docs/Tweens.md)
- [Reference Handles](docs/ReferenceHandles.md)
- [Object Picker](docs/ObjectPicker.md) - Unity-style reference picker: Scene/Project tabs, search, ping, project picks filtered by root component or file extension
- [SDL3 Renderer](docs/SDL3Renderer.md) - SDL3 + SDL_GPU rendering (Metal-native), per-camera render commands, scene view picking + selection outline + move/rotate/scale gizmos
- [Meshes](docs/Meshes.md) - glTF import with per-material submeshes, MeshFilter/MeshRenderer components
- [Materials](docs/Materials.md) - Material assets (built-in unlit/lit shaders + texture/color) on MeshRenderer AND SpriteRenderer, custom .glsl shaders with hot reload + property blocks + multi-texture rows, PBR/specular sample shaders (camera position + world position available to fragment shaders), directional Light component, live-editing inspector
- [SpriteRenderer](docs/SpriteRenderer.md)
- [Unity Conveniences](docs/UnityConveniences.md)

### Views
  - inspector view - edit selected object in scene
  - project inspector - preview and edit selected asset in project
  - hierarchy view - shows scene tree
  - project view - left pane is folder tree, right pane is selected folder contents
  - console view
  - scene view - view and edit scene contents

- custom drawers
  - custom property drawers - via @(property_drawer=...) on proc
  - custom decorator drawers - via field tags `decor:procName(arg=value)`

### Components
- Component menu - via @(component={menu="menu/path"}) on struct
  - adds to Component menu bar and Add Component button popup
  - if no menu path specified, type name is used

## TODO
- multiple/point lights (one directional Light per pass now)
- mesh tangents + linear color pipeline (pbr.glsl works around both in-shader)
- extract embedded glb textures on import + auto-create .mat with the right slot assignments (Unity model; today material wiring is manual)

- reorder collection elements in inspector by drag

- png - Texture2D with N Sprites
- bug: Refs show unresolved after undo
- don't depend tests on files in assets folder(fragile)

- transform:
  - use bit set + procs, instead of direct bool change
  - consider making transform regular component (required or optional), node will hold all components

- improve default types inspector UX

- improve transform context menu in hierarchy
  - fix copy/paste/duplicate bugs

- come up with more TODO and Considered features

- clear clipboard completely on each copy call

- keep improving memory guide
  - must be explained simply as if for someone new to memory handling

- Node graph editor for different use-cases
  - VFX graph

- Rethink Undo, should also work with assets in project and probably current selection
- Allow multiselection in scene and project. No multiedit yet

### Considered Features

- Task tracking with backlog, todo, etc.

- decide shaders and rendering pipeline

- some kind of type defaults fill only what json serialized data doesn't cover

- doc generation

- multiple views of same type support, with lock toggle
- popup manager
  - show serialized or in-memory asset inspector as popup with custom title
    - override property drawer for custom popup look

- convert tween_free to cleanup_T

- generalized serialization of Owned and Ref
- generic Handle resolve and reset Handle when resolve fails

- App buttons Bar
  - ?Frame Step, Pause buttons

- ability to switch Value/Ref field in inspector where valid

- Run configurations - dropdown to select config that runs game (release/debug, etc.) when press Play
- Ability to observe and edit app during its runtime
  - maybe create app_world:^World in user context, load main scene into it and switch views into working with app_world, not editor world

- Dirty flags for modified data
- file watcher for rebuilding and asset updates

- Convert resource into usable format at buildStage or runtimeStage

- consider SceneFile to hold serialize blobs instead of real types
