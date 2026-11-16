---
title: "Bloom"
description: "postfx_bloom: spreads what is brighter than a threshold into a glow through a chain of ever smaller images, for the tonemap to add"
weight: 40
tags: ["postfx", "render-steps"]
---

`postfx_bloom` spreads what is brighter than a threshold into a glow, at half size, into `bloom`, for the [Tonemap](Tonemap.md) to add. Reads `final` and, when present, `exposure`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `threshold` | 1 | Scene colour above it blooms, as exposed. |
| `strength` | 0.3 | How much the tonemap adds back, applied in the last pass. |
| `scatter` | 0.7 | How far the glow spreads, 0 to 1: 0 keeps it tight around what blooms, 1 lets the widest levels carry it. |
| `clamp` | 65472 | The brightest a pixel counts for. The default is the half-float range. |

## Behavior

- A bright pass at half size, then five levels down, each half the size of the one before, to a 64th of the view, and back up.
- Down, each level is filtered from 13 taps of the one above it, the pattern of Jimenez's "Next Generation Post Processing in Call of Duty: Advanced Warfare": wide and smooth, so the glow does not shimmer as the image moves.
- Up, each level is blended with the level below it, upsampled with a 3x3 tent filter, by `scatter`. The top level holds the glow of every size, and the last pass scales it by `strength`.
- The bright pass averages four taps per half-size pixel, each weighted by 1 / (1 + brightness), so a lone very bright pixel cannot flare into a glowing block.
- It multiplies the scene by the auto exposure first, so the threshold applies to the image as exposed: a lamp in a dark room blooms once the exposure has risen.
- Eleven passes: the bright pass and the last at half size, the others at a quarter of the view's size or smaller.
