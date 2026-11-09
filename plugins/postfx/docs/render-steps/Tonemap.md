---
title: "Tonemap"
description: "postfx_tonemap: exposure, bloom, colour grading, then HDR to LDR by an operator, then a lookup texture"
weight: 50
tags: ["postfx", "render-steps"]
---

`postfx_tonemap` turns the HDR image into the LDR one in a single pass: the exposures, the bloom added, colour grading, the operator, then a lookup texture. Writes `post`, the new final. Reads `final` and, when present, `bloom` and `exposure`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `operator` | ACES | None, Reinhard, ACES or ACES Hill. ACES Hill is Stephen Hill's fit of the ACES transforms, the curve the Khronos glTF Sample Viewer uses: with exposure 1 / 0.6 it matches the Sample Viewer's default look. |
| `exposure` | 1 | A multiplier before the operator, after the auto exposure. |
| `grading` | neutral | Colour grading, below. |

## Colour grading

Every default leaves the colour as it is.

- **In linear light, before the operator:**
  - White balance and `color_filter` as one 3 by 3 matrix. `temperature` makes it warmer or cooler and `tint` greener or more magenta, each -100 to 100. `temperature` 100 treats the scene's white as light of 13000 K and adapts it to 6500 K along the black-body curve, -100 as 3250 K. `tint` moves that white across the curve.
  - `contrast`, -100 to 100, around middle grey, 0.18, in log2.
  - `hue_shift` in degrees, a turn around the grey axis, and `saturation`, from -100 greyscale to 100 twice as colourful, as a second matrix.
- **After the operator, in display values:** `lut`, a lookup texture, blended in by `lut_contribution`.

The two matrices are built on the CPU per draw, so the shader costs two matrix multiplies whatever is set.

## Lookup textures

A lookup texture is a strip of N squares, N texels on a side: 1024 by 32 for N = 32. Red runs across each square, green down it, and blue picks the square, left to right. `assets/neutral_lut_32.png` changes nothing, within 8-bit rounding. To make one: take a screenshot, grade it in an image editor, apply the same adjustments to the neutral strip, and assign the result. A texture of another shape is not applied, with one warning.
