---
title: "Shadow cascades"
description: "shadow_cascades: the first shadowing directional light's cascades, fitted to the view"
weight: 40
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`shadow_cascades` renders the first shadowing directional light's shadow cascades, fitted to the view. Reads `scene`, writes `shadow`, a 2048 pixel depth target.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `cascades` | 4 | Slices of the camera's frustum, 1 to 4, each its own tile. More keeps near shadows sharp further out. |
| `distance` | 50 | Shadows end this far from the camera, fading over the last tenth. |
| `split` | 0.75 | How the slices divide the distance: 0 evenly, 1 logarithmically, with more detail near the camera. |
| `bias` | 0.05 | World units toward the light, against self-shadowing acne. |
| `normal_bias` | 1.5 | Texels along the surface normal, for faces at a grazing angle. |

## Behavior

Each slice is an orthographic view of the sphere around it, so its size does not change as the camera turns and its edges do not shimmer as the camera moves ([Materials](../Materials.md), "Light component").
