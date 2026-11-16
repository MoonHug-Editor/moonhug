---
title: "Camera"
description: "Renders the scene from its object, through a render pipeline slot, in perspective or orthographic, with clip planes, clear colour and render layers"
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

```
Map Camera    Camera projection Orthographic, orthographic_size 20, rotation looking straight down
```

A top-down map: the view is 40 metres high at every distance, and things keep their size however far below the camera they are.

## Properties

| Field | Default | What it does |
|---|---|---|
| `order` | 0 | Cameras render in ascending order. The lowest clears with its `clear_color`, later ones draw over it. Game code's mouse rays use the highest-order enabled camera. |
| `projection` | Perspective | Perspective draws distant things smaller. Orthographic draws everything at its size at every distance: 2D games, top-down and isometric views. |
| `fov` | 60 | Perspective: the vertical field of view in degrees, 1 to 179. |
| `orthographic_size` | 5 | Orthographic: half the visible height in world units. The width follows from the view's aspect. |
| `near_clip`, `far_clip` | 0.3, 1000 | The nearest and farthest distances drawn. |
| `clear_color` | dark blue | What the lowest-order camera clears to, where no sky draws. |
| `render_layer_mask` | all | The render layers this camera draws ([Layers](../Layers.md)). |
| `slot` | Main | The render pipeline slot this camera renders through. A slot the pipeline does not declare falls back to Main, with one warning ([Render pipeline](../RenderPipeline.md)). |

## Behavior

- Every enabled camera renders each frame into the Game window or the game's screen.
- Cameras cull meshes outside their view.
- An [Environment](Environment.md)'s sky draws behind the cameras instead of the clear colour when its `draw_sky` is on.

## In the editor

A selected camera draws its frustum in the Scene window, a box for an orthographic camera.

## Limits

- No viewport rectangle: every camera fills the whole view.
- Lit shading takes its view direction from the camera's position in both projections, so an orthographic camera close to a shiny surface places highlights as a perspective one would.
