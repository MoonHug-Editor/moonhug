---
title: "Ambient occlusion"
description: "scene_ssao: screen-space ambient occlusion from the view's depth, shading the environment's light of the lit draws"
weight: 50
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_ssao` darkens creases, corners and the ground under objects: how much of the hemisphere above each pixel's surface the view's depth leaves open. Placed before `scene_opaque`, which reads its `ssao` target. Reads `scene`, writes `ssao` and a blur target. Muted in the default pipeline.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `radius` | 0.5 | How far around a point occluders count, in world units. |
| `intensity` | 1 | How dark a fully occluded point gets. |
| `samples` | 12 | Samples per pixel, 4 to 32. |
| `direct` | 0.25 | How much of the occlusion also darkens direct light. 0 shades only the environment's light. |

## Behavior

- It draws the depth itself when no `depth_prepass` ran before it, and `scene_opaque` keeps that depth.
- Two blur passes smooth the noise without crossing an object's edge.
- The Scene window's debug modes skip it ([Render pipeline](../RenderPipeline.md), "Ambient occlusion").
