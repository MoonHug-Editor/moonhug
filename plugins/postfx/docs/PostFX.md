---
title: "Post FX"
description: "Bloom, tonemap operators and FXAA as render steps a pipeline places between the engine's scene steps and its final blit, each with its own settings"
order: 10
tags: ["rendering", "plugins"]
---

The postfx plugin ships three render steps (plugins/engine/docs/RenderPipeline.md). The default pipeline places them in its Main lane after `scene_over` and before `final_blit`, in this order:

| Step | Reads | Writes | What |
|---|---|---|---|
| `postfx_bloom` | `final` (the scene's HDR image) | `bloom:HDR@0.5` and two scratch targets | a bright pass above the threshold, then a horizontal and a vertical gaussian blur |
| `postfx_tonemap` | `final` and `bloom?` (optional) | `post:LDR*` | exposure, the bloom added, then the operator: none, Reinhard, ACES or ACES Hill |
| `postfx_fxaa` | `final` | `aa:LDR*` | fast approximate anti-aliasing |

Each step reads the finished image so far (`reads="final"`, `engine.render_input`) and takes its own target from its declaration (`engine.render_target`), whose `*` makes it the new final, so the engine's `final_blit` copies whichever step ran last. Removing a step from the pipeline removes its effect: without `postfx_fxaa` the tonemap output is the final, without all three the scene's HDR image is, the engine's own look. The tonemap adds bloom only when a bloom step ran before it in the lane: its `bloom` read is optional, and the bloom image already holds the light to add, the strength applied, so the tonemap needs nothing else from the bloom step.

## Settings

Per placed step, in the Render Pipeline window's settings pane, stored in the pipeline asset:

- `postfx_bloom`: `threshold` (scene color above it blooms), `strength` (how much the tonemap adds back, applied in the last blur pass), `clamp` (the brightest a scene pixel counts for, half-float range by default). The bright pass averages four taps per half-size pixel weighted by 1 / (1 + brightness) (Karis), so a lone very bright pixel cannot flare into a glowing block
- `postfx_tonemap`: `operator` (None, Reinhard, ACES, ACES Hill), `exposure` (multiplier before the operator). ACES Hill is Stephen Hill's fit of the ACES transforms, the curve the Khronos glTF Sample Viewer uses: with exposure 1 / 0.6 it matches the Sample Viewer's default look
- `postfx_fxaa`: none

## The shaders

`assets/resources/shaders/*.glsl` are ordinary fragment shaders compiled by the shader importer, registered as fullscreen shaders through `engine.shader_load_fullscreen` (the fullscreen vertex stage gives them `frag_uv` only). Inputs are samplers at `set = 2`, the property block a `vec4 params` at `set = 3, binding = 1`. They sit under `resources` so an export ships them, since nothing in a scene references them.

## Removing the plugin

Delete the `moonhug/packages/postfx` link and build. No engine file knows the plugin. A pipeline that placed its steps warns once that they are not installed and renders without them.
