---
title: "Motion vectors"
description: "motion_vectors: how far each pixel of a moved mesh moved on screen, for TAA and motion blur"
weight: 120
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`motion_vectors` draws the meshes whose model changed since the view's last frame into `motion`, against the scene's depth: each pixel holds how far it moved on screen. Reads `scene` and `hdr`.

- A frame where nothing moved draws nothing and costs only the check.
- It runs with or without `scene_taa`, keeping the view's last camera itself, for the postfx plugin's motion blur.
- A skinned mesh's motion follows its model only, and transparent objects have no motion vectors ([Render pipeline](../RenderPipeline.md), "Temporal anti-aliasing").
