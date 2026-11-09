---
title: "Depth prepass"
description: "depth_prepass: the opaque meshes' depth before shading, so each pixel is shaded once"
weight: 45
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`depth_prepass` draws the opaque meshes' depth before shading, alpha-clipped ones through their caster, and `scene_opaque` keeps it, so each covered pixel is shaded once. Reads `scene`, writes `hdr`.

- It is installed but not in the default pipeline. Placed before `scene_opaque` it costs a second pass over the geometry, so it pays off with expensive materials and heavy overdraw on a GPU-bound frame.
- `scene_ssao` and `scene_ssr` use its depth when it ran before them.
- The Scene window's debug modes skip it.
