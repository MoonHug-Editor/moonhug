---
title: "Reflection probes"
description: "reflection_probes_pass: captures each Reflection Probe that needs it into its cube"
weight: 30
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`reflection_probes_pass`, a frame step after `shadow_atlas`. Captures each [Reflection Probe](../components/ReflectionProbe.md) that needs it: the first time it is seen, when it moved or changed, or every frame. Reads `scene`.

- A capture renders six faces from the probe's position through a lane of its own made of `shadow_cascades`, `scene_opaque`, `scene_sky` and `scene_transparent`, not the pipeline's slot, so no anti-aliasing, post effect or screen reflection runs in it.
- The faces are prefiltered into the probe's reflection cube, and with `diffuse` on into its diffuse light ([Render pipeline](../RenderPipeline.md), "Reflection probes").
