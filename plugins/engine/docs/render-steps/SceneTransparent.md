---
title: "Transparent"
description: "scene_transparent: draws the transparent meshes and the alpha-blended quads back to front"
weight: 110
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_transparent` draws the transparent meshes and the alpha-blended quads, sprites, particles and UI, back to front by their sort keys. Reads `scene`, `hdr` and, when present, `shadow`, `shadow_atlas` and `scene_color`. Writes `hdr`.
