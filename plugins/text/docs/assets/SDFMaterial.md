---
title: "SDF material"
description: "The shader and material text draws with: a sharp edge at any size, outline, shadow, softness and dilation"
weight: 20
tags: ["text", "assets"]
---

The shader and material text draws with: `shaders/text_sdf.glsl` and `materials/TextSDF.mat`. The shader thresholds the field at 0.5 with an anti-aliasing width taken from the field's screen-space slope, so the edge is one pixel soft at every size. With a plain unlit material the raw field would draw as blurred blobs.

## Material properties

In field units unless noted.

| Property | What it does |
|---|---|
| `outline_color`, `outline_width` | A second threshold outside the face. |
| `underlay_color`, `underlay_offset`, `underlay_softness` | A shadow: the field sampled at an offset, blurred and drawn behind. The offset is in atlas UV units, about 0.002 per pixel at 1024. |
| `softness` | Extra blur on the glyph's edge. |
| `dilate` | Grows or thins the glyph. |

Make a copy of the material for each look, and pick it in the Text's `material`. It is a user shader through the material system ([Materials](/plugins/engine/docs/Materials.md)).
