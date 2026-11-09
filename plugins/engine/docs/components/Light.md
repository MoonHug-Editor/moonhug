---
title: "Light"
description: "A directional, point or spot light, with colour, intensity, range, cone, shadows and the render layers it lights"
weight: 20
tags: ["engine", "rendering", "components"]
path: engine/components
---

Lights the scene from its object: a directional light along its -Z, or a point or spot light at its position.

## Example

```
Sun        Light type Directional, intensity 3, shadows Shadows
Lamp       Light type Point, color warm white, range 6
Spotlight  Light type Spot, spot_angle 40, range 12
```

The sun lights the whole scene along its -Z and casts shadows. The lamp lights a sphere around it, and the spotlight a cone.

## Properties

| Field | Default | What it does |
|---|---|---|
| `type` | Directional | Directional, Point or Spot. |
| `color` | white | The light's colour. |
| `intensity` | 1 | How bright it is. |
| `range` | 10 | Point and spot: where the falloff reaches zero. |
| `spot_angle` | 30 | Spot: the full cone angle in degrees. |
| `inner_spot_angle` | 21.8 | Spot: the full-brightness cone in degrees. |
| `ambient` | 0.35 | The unlit floor, 0 to 1. The first enabled light's value is used. |
| `shadows` | Shadows | Shadows or None. |
| `culling_mask` | all | The render layers it lights. A mesh on none of them gets no light from it. |
| `shadow_caster_mask` | all | The render layers that cast into its shadow map. |

## Behavior

- The first shadowing directional light casts through cascades fitted to each camera's view. Spot and point lights cast through tiles of a shadow atlas ([Materials](../Materials.md), "Light component").
- The first enabled directional light is also the [Environment](Environment.md)'s sun: its direction and colour.

## In the editor

A selected light shows its range and cone in the Scene window.
