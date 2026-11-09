---
title: "Bloom"
description: "postfx_bloom: blurs what is brighter than a threshold at half size, for the tonemap to add"
weight: 40
tags: ["postfx", "render-steps"]
---

`postfx_bloom` blurs what is brighter than a threshold, at half size, into `bloom`, for the [Tonemap](Tonemap.md) to add. Reads `final` and, when present, `exposure`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `threshold` | 1 | Scene colour above it blooms, as exposed. |
| `strength` | 0.3 | How much the tonemap adds back, applied in the last blur pass. |
| `clamp` | 65472 | The brightest a pixel counts for. The default is the half-float range. |

## Behavior

- A bright pass, then a horizontal and a vertical gaussian blur.
- The bright pass averages four taps per half-size pixel, each weighted by 1 / (1 + brightness), so a lone very bright pixel cannot flare into a glowing block.
- It multiplies the scene by the auto exposure first, so the threshold applies to the image as exposed: a lamp in a dark room blooms once the exposure has risen.
