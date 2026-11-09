---
title: "postfx"
description: "Post-processing render steps: motion blur, depth of field, auto exposure, bloom, tonemapping with colour grading, and FXAA"
tags: ["postfx", "rendering", "plugin"]
---

The postfx plugin adds six render steps a render pipeline places after the engine's scene steps ([Render pipeline](/plugins/engine/docs/RenderPipeline.md)). Each has its own settings, stored per placed step in the pipeline asset and edited in the Render Pipeline window's settings pane.

## What it adds

**Render steps**, in the default pipeline's order:

| Step | What it does |
|---|---|
| [Motion blur](render-steps/MotionBlur.md) | Smears each pixel along how far it moved since last frame. Muted by default. |
| [Depth of field](render-steps/DepthOfField.md) | Blurs the scene by its distance from the focus, through a thin lens. Muted by default. |
| [Auto exposure](render-steps/AutoExposure.md) | Meters the scene's brightness and adapts the exposure to it over time. Muted by default. |
| [Bloom](render-steps/Bloom.md) | Blurs what is brighter than a threshold, for the tonemap to add. |
| [Tonemap](render-steps/Tonemap.md) | Exposure, bloom, colour grading, then HDR to LDR by an operator. |
| [FXAA](render-steps/FXAA.md) | Fast approximate anti-aliasing. Not in the default pipeline. |

## How the steps chain

- The default pipeline places motion blur and depth of field right after `scene_taa`, and auto exposure, bloom and tonemap after them and before `scene_over`, which draws the gizmos onto the finished image, so the gizmos stay sharp. FXAA is not in it: add it after the tonemap.
- A step reads the finished image so far, `final`, and writes its own target. A `*` on that target makes it the new final, so the engine's `final_blit` copies whichever step ran last.
- Removing a step removes its effect. Without FXAA the tonemap's output is the final, and without bloom, tonemap and FXAA the scene's HDR image is, the engine's own look.
- The tonemap adds bloom only when a bloom step ran before it in the lane. Without an exposure step the auto exposure is 1.
- The Scene window's debug modes skip motion blur and depth of field.

## What it needs

- The engine plugin and its render pipeline.

## The shaders

`assets/resources/shaders/*.glsl` are ordinary fragment shaders, compiled by the shader importer and loaded as fullscreen shaders with `engine.shader_load_fullscreen`, which gives them `frag_uv` only. Inputs are samplers at `set = 2`, and the settings at `set = 3, binding = 1`. They sit under `resources` so an export ships them, since no scene references them.

## Extending

The plugin declares no attributes of its own. Each step is the engine's `@(render_step)` on a proc, which is how a plugin adds a step ([Render pipeline](/plugins/engine/docs/RenderPipeline.md)).

## Removing it

Delete the `moonhug/packages/postfx` link and build. No engine file knows the plugin. A pipeline that placed its steps warns once that they are not installed and renders without them.

## Reference

- [API reference](/docs/reference/packages/postfx/postfx.md) of the `postfx` package.
