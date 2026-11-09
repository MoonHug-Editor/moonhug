---
title: "Screen-space reflections"
description: "scene_ssr: screen-space reflections from the view's depth, normals and last frame's opaque image"
weight: 60
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_ssr` mirrors what is on screen in smooth surfaces: a glossy floor shows the objects on it. Placed before `scene_opaque`, whose lit draws put it in place of the environment's reflection by its confidence. Reads `scene`, writes `ssr` and its scratch targets. Muted in the default pipeline.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `max_distance` | 20 | How far a reflected ray travels, in world units. |
| `thickness` | 0.3 | How far behind a surface a ray still counts as hitting it. |
| `back_faces` | on | Draws the meshes' far sides too, so a ray entering a closed mesh hits it. One more depth pass. |
| `steps` | 48 | Samples along each ray, 8 to 128. |
| `edge_fade` | 0.1 | The part of the screen toward its edges over which reflections fade out. |

## Behavior

- The colour at a hit comes from last frame's opaque image, the `scene_color` target `scene_copy` leaves. It warns once when the lane has no `scene_copy`.
- Rougher surfaces read it blurrier, and it fades out between roughness 0.5 and 0.8.
- Transparent surfaces reflect the environment only. The Scene window's debug modes skip it ([Render pipeline](../RenderPipeline.md), "Screen-space reflections").
