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

For more details see [Contribution](features/Contribution.md)

## Introduction video
[![](http://img.youtube.com/vi/TQLF-db3Jqs/0.jpg)](https://www.youtube.com/watch?v=TQLF-db3Jqs)

## Contribution
- [Contribution](features/Contribution.md)

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
- vendor:raylib - for Editor's window creation and graphics rendering

## Features
- menu bar - customizable via @(menu_item=...) on proc

- union serialization (#no_nil unions only)

- [Asset Pipeline](features/AssetPipeline.md) - asset importer/loader
- [Scenes](features/Scenes.md)
- [Tweens](features/Tweens.md)
- [Reference Handles](features/ReferenceHandles.md)
- [SpriteRenderer](features/SpriteRenderer.md)
- [Unity Conveniences](features/UnityConveniences.md)

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
- each camera has int order and render_commands buffer
- Cameras scan scene trees for renderers to add render commands to commands buffers
  - transforms have render layer field for camera culling
  - then render commands buffer is applied

- scene or scene_manager should have map of local_id to avoid collisions

- scene view gizmos
  - scene view toolbar (move, rotate, scale)

- png - Texture2D with N Sprites

- improve default types inspector UX

- Asset search / filter in Project View A single text input that filters the visible files by name substring

- improve transform context menu in hierarchy
  - copy — serialize transform tree (no clipboard, use editor state)
  - paste — decide what to do with copied info in current context
  - duplicate — same as copy paste but without copying into system buffer

- copy/ paste - right-click a field in the Inspector → "Copy" / "Paste" into another of the same type (no cipboard, use editor state)

- Scene view picking - click on a sprite/object in the Scene view to set it as the hierarchy selection

- come up with more TODO and Considered features

- Editor Undo system

### Considered Features
- Task tracking with backlog, todo, etc.

- decide shaders and rendering pipeline

- ping reference object similar to Unity

- nested prefabs
- prefab overrides

- doc generation

- multiple views of same type support, with lock toggle
- popup manager
  - show serialized or in-memory asset inspector as popup with custom title
    - override property drawer for custom popup look

- generalized serialization of Owned and Ref
- generic Handle resolve and reset Handle when resolve fails

- scene view gizmos and GUI

- App buttons Bar
  - ?Frame Step, Pause buttons

- Run configurations - dropdown to select config that runs game (release/debug, etc.) when press Play
- Ability to observe and edit app during its runtime
  - maybe create app_world:^World in user context, load main scene into it and switch views into working with app_world, not editor world

- code style guide for better quality and reading
- memory management guide

- Dirty flags for modified data
- file watcher for rebuilding and asset updates

- Convert resource into usable format at buildStage or runtimeStage

- consider SceneFile to hold serialize blobs instead of real types

- Node graph editor for different use-cases
