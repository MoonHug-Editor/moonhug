---
title: "Volume"
description: "Overrides render step settings inside a box or everywhere, blended by weight, distance and priority"
weight: 50
tags: ["engine", "rendering", "components"]
path: engine/components
---

Overrides the settings of render pipeline steps inside a box, or everywhere, for a camera that is inside. Bloom stronger in a cave, depth of field focused in a cutscene ([Render pipeline](../RenderPipeline.md), "Volumes").

## Example

```
Cave       Volume size 20, 6, 30, blend_distance 3, overrides postfx_bloom strength 0.8
```

Bloom is stronger while the camera is inside the cave, and blends back to the pipeline's setting over 3 metres as it leaves.

## Properties

| Field | Default | What it does |
|---|---|---|
| `global` | off | Applies everywhere, whatever the camera's position. Otherwise inside the box. |
| `size` | 10, 10, 10 | The box, around the transform, in its space: its scale scales the box. |
| `blend_distance` | 1 | World units outside the box over which the volume fades in. 0 switches at the edge. |
| `weight` | 1 | How much of its overrides apply at full strength, 0 to 1. |
| `priority` | 0 | A higher priority blends in later, over lower ones. |
| overrides | none | The step settings it overrides, edited by the Volume's own rows: pick a step, then the settings to override. |

## Behavior

- Each frame, for each camera, every step's settings start from the pipeline's values and blend in each Volume the camera is inside, by priority, by its weight times how far inside the camera is.

## In the editor

A selected volume draws its box in the Scene window, and its rows pick the steps and settings it overrides.
