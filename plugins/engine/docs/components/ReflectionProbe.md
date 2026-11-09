---
title: "Reflection Probe"
description: "Captures the scene around it into a box, so meshes inside reflect the room instead of the sky"
weight: 40
tags: ["engine", "rendering", "components"]
path: engine/components
---

Captures the scene around its position into a box. Meshes inside the box reflect the room, and optionally take its diffuse light, instead of the [Environment](Environment.md)'s sky. The component type is `Reflection_Probe`.

## Example

```
Hall       Reflection_Probe size 12, 4, 20, box_projection on, refresh Once
```

Shiny floors and walls inside the hall reflect the hall itself instead of the sky. Box projection lines the reflections up with the walls.

## Properties

| Field | Default | What it does |
|---|---|---|
| `size` | 10, 10, 10 | The box, in world units around the position, aligned to the world. |
| `blend_distance` | 1 | How far inside the box's edge a mesh starts fading into the next smaller box, or the Environment. 0 switches at the edge. |
| `box_projection` | on | Reflects the box's walls where they are, as fits a room. Off reflects at infinity, as fits open ground. |
| `diffuse` | on | Lights the meshes inside with the room's diffuse light as captured. |
| `intensity` | 1 | How bright the reflection and the diffuse light are. |
| `culling_mask` | all | The render layers the capture draws. A mirror-like object leaves its own layer out so it does not reflect itself. |
| `resolution` | 128 | 64, 128 or 256 pixels per cube face. |
| `refresh` | Once | Once captures when the probe is first seen, moves or changes. Every_Frame captures every frame, at six scene renders a frame. |

## Behavior

- A mesh takes the smallest box that holds it. Neighbouring rooms' boxes overlap by the blend distance to crossfade.
- A MeshRenderer with `reflections` Hidden is left out of every capture.

## In the editor

A selected probe draws its box in the Scene window.
