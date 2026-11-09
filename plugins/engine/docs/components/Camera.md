---
title: "Camera"
description: "Renders the scene from its object, through a render pipeline slot, with field of view, clip planes, clear colour and render layers"
weight: 10
tags: ["engine", "rendering", "components"]
path: engine/components
---

Renders the scene from its object's position and rotation, looking along its -Z.

## Example

```
Main Camera    Camera fov 60, far_clip 500, render_layer_mask all but Hidden
```

The game renders from this camera through the pipeline's Main slot. It sees everything within 500 metres, except objects on the Hidden render layer.

## Properties

| Field | Default | What it does |
|---|---|---|
| `order` | 0 | Cameras render in ascending order. The lowest clears with its `clear_color`, later ones draw over it. Game code's mouse rays use the highest-order enabled camera. |
| `fov` | 60 | The vertical field of view in degrees, 1 to 179. |
| `near_clip`, `far_clip` | 0.3, 1000 | The nearest and farthest distances drawn. |
| `clear_color` | dark blue | What the lowest-order camera clears to, where no sky draws. |
| `render_layer_mask` | all | The render layers this camera draws ([Layers](../Layers.md)). |
| `slot` | Main | The render pipeline slot this camera renders through. A slot the pipeline does not declare falls back to Main, with one warning ([Render pipeline](../RenderPipeline.md)). |

## Behavior

- Every enabled camera renders each frame into the Game window or the game's screen.
- Cameras cull meshes outside their view.
- An [Environment](Environment.md)'s sky draws behind the cameras instead of the clear colour when its `draw_sky` is on.

## In the editor

A selected camera draws its frustum in the Scene window.

## Limits

- Perspective only. No orthographic projection and no viewport rectangle.
