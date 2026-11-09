---
title: "Opaque"
description: "scene_opaque: clears the view and draws the opaque meshes"
weight: 70
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_opaque` clears the view and draws the opaque meshes, lit and shadowed. Reads `scene` and, when present, `shadow`, `shadow_atlas`, `ssao` and `ssr`. Writes `hdr`, the new final.

- When a depth prepass, `scene_ssao` or `scene_ssr` drew the depth first, it keeps that depth and shades each covered pixel once.
