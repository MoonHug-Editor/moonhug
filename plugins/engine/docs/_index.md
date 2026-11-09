---
title: "Engine"
description: "The engine plugin: its components, its data model, scenes and prefabs, the frame, and rendering"
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

**Concepts**

- [Data](concepts/data/_index.md): the world, pools and handles, the component data layer, references and groups.
- [Scenes](concepts/scenes/_index.md): scene files, prefabs and nested prefabs.
- [Frame](concepts/frame/_index.md): the fixed tick and the order updates and lifecycle procs run in.
- [Rendering](concepts/rendering/_index.md): the renderer, the render pipeline, materials, meshes, render layers and the UI canvas.

## Reference

- [API reference](/docs/reference/packages/engine/engine.md) of the `engine` package.
- Its attributes, under [Reference, attributes, engine](/docs/reference/attributes/engine/_index.md).
