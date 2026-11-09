---
title: "CanvasScaler"
description: "Sets how canvas units map to screen pixels: constant pixel size, or scaled with the screen to a reference resolution"
weight: 130
tags: ["engine", "ui", "components"]
path: engine/components
---

Sets how canvas units map to screen pixels. It sits on the Canvas node. Without one, one canvas unit is one screen pixel.

## Properties

| Field | Default | What it does |
|---|---|---|
| `mode` | Scale With Screen Size | Constant Pixel Size or Scale With Screen Size. |
| `scale_factor` | 1 | Constant Pixel Size: screen pixels per canvas unit. |
| `reference_resolution` | 1920, 1080 | Scale With Screen Size: the canvas's size in units, scaled to fit the screen. |
| `match` | 0.5 | Scale With Screen Size: 0 fits the reference width, 1 the height, values between blend logarithmically. |

Rects, the rect tool and the Scene window work in canvas units. The Game window maps them to pixels.
