---
title: "Shadow atlas"
description: "shadow_atlas: spot and point light shadows, a tile per spot light and six per point light"
weight: 20
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`shadow_atlas`, a frame step. Renders spot and point lights' shadows into one atlas: a tile per spot light, six per point light. Reads `scene`, writes `shadow_atlas`, a 2048 pixel depth target.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `bias` | 0.05 | World units along the light ray: hides self-shadowing acne at the cost of a little detachment at contact. |
| `normal_bias` | 1.5 | Texels along the surface normal, the same trade for faces at a grazing angle. |

## Behavior

- Each tile culls against its own light view and the light's `shadow_caster_mask`.
- It runs once per frame and world, so Volumes do not change its settings.
