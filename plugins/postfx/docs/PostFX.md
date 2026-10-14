---
title: "Post FX"
description: "Bloom, tonemap operators and FXAA as render nodes a pipeline places between the engine's scene nodes and its final blit, each with its own settings"
order: 10
tags: ["rendering", "plugins"]
---

The postfx plugin ships three render nodes (plugins/engine/docs/RenderPipeline.md). The default pipeline places them in its Main lane after `scene_over` and before `final_blit`, in this order:

| Node | Reads | Writes | What |
|---|---|---|---|
| `postfx_bloom` | `final` (the scene's HDR image) | `bloom:HDR@0.5` and two scratch targets | a bright pass above the threshold, then a horizontal and a vertical gaussian blur |
| `postfx_tonemap` | `final` and `bloom` | `post:LDR*` | exposure, the bloom added, then the operator: none, Reinhard or ACES |
| `postfx_fxaa` | `final` | `aa:LDR*` | fast approximate anti-aliasing |

Each node reads the finished image so far (`reads="final"`, `engine.render_input`) and takes its own target from its declaration (`engine.render_target`), whose `*` makes it the new final, so the engine's `final_blit` copies whichever node ran last. Removing a node from the pipeline removes its effect: without `postfx_fxaa` the tonemap output is the final, without all three the scene's HDR image is, the engine's own look. The tonemap adds bloom only when a bloom node ran before it in the lane.

## Settings

Per placed node, in the Render Pipeline window's settings pane, stored in the pipeline asset:

- `postfx_bloom`: `threshold` (scene color above it blooms), `strength` (how much the tonemap adds back)
- `postfx_tonemap`: `operator` (None, Reinhard, ACES), `exposure` (multiplier before the operator)
- `postfx_fxaa`: none

## The shaders

`assets/resources/shaders/*.glsl` are ordinary fragment shaders compiled by the shader importer, registered as fullscreen shaders through `engine.shader_load_fullscreen` (the fullscreen vertex stage gives them `frag_uv` only). Inputs are samplers at `set = 2`, the property block a `vec4 params` at `set = 3, binding = 1`. They sit under `resources` so an export ships them, since nothing in a scene references them.

## Removing the plugin

Delete the `moonhug/packages/postfx` link and build. No engine file knows the plugin. A pipeline that placed its nodes warns once that they are not installed and renders without them.
