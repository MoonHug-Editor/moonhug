---
title: "TAA"
description: "scene_taa: temporal anti-aliasing, each frame's sub-pixel offset blended into the view's history"
weight: 130
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_taa` smooths edges and thin highlights over several frames. When a lane holds it, the scene steps before it draw through a camera offset by a fraction of a pixel, a different offset each frame, and it blends each frame into the view's history and writes the result back into `hdr`. Reads `hdr` and, when present, `motion`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `blend` | 0.1 | How much of each frame goes into the result, 0.02 to 0.5. Lower is smoother and steadier, higher follows motion with less ghosting. |

## Behavior

- Each pixel finds where it was last frame through the camera's motion and, where `motion_vectors` drew, the object's own.
- The history is clipped to this frame's neighbourhood, so what was uncovered or changed does not ghost.
- Each view keeps its own history. A view that skipped a frame or changed size starts over.
- It goes before `scene_over`, so the editor's gizmos stay sharp ([Render pipeline](../RenderPipeline.md), "Temporal anti-aliasing").
