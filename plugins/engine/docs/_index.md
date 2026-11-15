---
title: "Engine"
description: "The engine plugin: its components, assets and attributes, its data model, scenes and prefabs, the frame, and rendering"
weight: 25
path: engine
---

The engine plugin is everything a game runs on: the world of pools and handles, scenes and prefabs, the frame and the fixed tick, the renderer and its pipeline, and the components that place, draw and light objects. [Architecture](/docs/core/Architecture.md) places it among the Editor and the App.

## What it adds

**Components**

- Rendering: [Camera](components/Camera.md), [Light](components/Light.md), [Environment](components/Environment.md), [Reflection Probe](components/ReflectionProbe.md) and [Volume](components/Volume.md).
- Meshes: [MeshFilter](components/MeshFilter.md), [MeshRenderer](components/MeshRenderer.md) and [SkinnedMeshRenderer](components/SkinnedMeshRenderer.md).
- UI canvas: [Canvas](components/Canvas.md), [RectTransform](components/RectTransform.md), [CanvasRenderer](components/CanvasRenderer.md), [CanvasScaler](components/CanvasScaler.md) and [GraphicRaycaster](components/GraphicRaycaster.md).
- Scene: [Groups](components/Groups.md).

**Assets**

- [Texture](assets/Texture.md), [Model](assets/Model.md) and [Shader](assets/Shader.md): imported files.
- [Material](assets/Material.md), [Render Pipeline](assets/RenderPipeline.md), [Render Layers](assets/RenderLayers.md), [Group Names](assets/GroupNames.md) and [Scene](assets/Scene.md): made with Assets, Create.

**Windows**

- [Hierarchy](windows/Hierarchy.md): the loaded scenes and their objects.
- [Inspector](windows/Inspector.md): the selected objects' components.
- [Render Pipeline](windows/RenderPipeline.md): a pipeline's passes and resources as a matrix, with live thumbnails.

**Render steps**

- Frame lane: [Environment](render-steps/EnvironmentPass.md), [Shadow atlas](render-steps/ShadowAtlas.md) and [Reflection probes](render-steps/ReflectionProbesPass.md).
- Scene: [Shadow cascades](render-steps/ShadowCascades.md), [Depth prepass](render-steps/DepthPrepass.md), [Ambient occlusion](render-steps/SceneSsao.md), [Screen-space reflections](render-steps/SceneSsr.md), [Opaque](render-steps/SceneOpaque.md), [Sky](render-steps/SceneSky.md), [Scene copy](render-steps/SceneCopy.md), [Scene under](render-steps/SceneUnder.md) and [Transparent](render-steps/SceneTransparent.md).
- After the scene: [Motion vectors](render-steps/MotionVectors.md), [TAA](render-steps/SceneTaa.md), [Scene over](render-steps/SceneOver.md) and [Final blit](render-steps/FinalBlit.md).

**Concepts**

- [Data](concepts/data/_index.md): the world, pools and handles, the component data layer and references.
- [Scenes](concepts/scenes/_index.md): scene files, prefabs and nested prefabs.
- [Frame](concepts/frame/_index.md): the fixed tick and the order updates and lifecycle procs run in.
- [Rendering](concepts/rendering/_index.md): the renderer, the render pipeline, materials, meshes, render layers and the UI canvas.

## Project settings

Edit, Project Settings. Each tab is saved in `ProjectSettings/<name>.json`, which the game reads too.

| Tab | Setting | Default | What it does |
|---|---|---|---|
| Rendering | `pipeline` | none | The render pipeline the project renders through. None is the essentials plugin's `Default.renderpipeline` ([Render pipeline](RenderPipeline.md)). |
| Layers | `render_layers` | none | The Render Layers asset naming the render layers ([Layers](Layers.md)). |
| Groups | `group_names` | none | The Group Names asset naming the groups ([Groups](components/Groups.md)). |
| Time | `fixed_rate` | 60 | Fixed simulation ticks per second ([Fixed tick](FixedTick.md)). |
| Player | `title` | App | The game window's title. |
| Player | `width`, `height` | 800, 600 | The game window's size. |
| Player | `boot_scene` | empty | The scene guid the player boots when no program argument and no exported boot scene names one. |

## Extending

Attributes are the main way to extend the engine. A proc or a struct declares one, and the next prebuild wires it in, with no registration call:

- [Components](attributes/Components.md): `@(component)` makes a struct a component.
- [Lifecycle](attributes/Lifecycle.md): `@(comp_awake)`, `@(comp_on_enable)`, `@(comp_on_disable)` and `@(comp_on_destroy)`.
- [Updates](attributes/Updates.md): `@(update)`, `@(fixed_update)` and `@(late_update)`, as systems or per component.
- [Physics callbacks](attributes/PhysicsCallbacks.md): collision and trigger enter and exit.
- [Rendering](attributes/Rendering.md): `@(render_step)` and `@(render_collector)`.
- [UI canvas](attributes/UICanvas.md): `@(canvas_graphic)` and `@(canvas_layout)`.

The other ways:

- **Assets with no code.** A Render Pipeline asset places and configures steps, and a `.glsl` surface shader or a shader graph gives a Material its own look ([Materials](Materials.md), "Custom user shaders").
- **Physics libraries.** A physics plugin reports its contacts with `physics_contact_dispatch`, which runs the physics callbacks ([Component data](Components.md), "Physics contact hooks").
- **Attributes of the libs and the editor.** `@(phase)` runs code at engine start, scene load and shutdown, `@(typ_guid)` gives a type its file identity, and the editor's attributes add windows, menus, property drawers and importers ([libs](/docs/reference/attributes/libs/_index.md), [editor](/docs/reference/attributes/editor/_index.md)).

## Reference

- [API reference](/docs/reference/packages/engine/engine.md) of the `engine` package.
- Its attributes, under [Reference, attributes, engine](/docs/reference/attributes/engine/_index.md).
