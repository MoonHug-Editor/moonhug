---
title: "Environment"
description: "The sky, the ambient and reflected light it gives surfaces, and fog: procedural, panorama or flat colour"
weight: 30
tags: ["engine", "rendering", "components"]
path: engine/components
---

The sky behind the cameras, the light it gives surfaces, and fog. One per scene is enough: the first enabled one is used.

## Example

```
Environment    Environment sky Panorama, panorama Studio.hdr, fog Exponential, density 0.02
```

The scene's sky is an HDR panorama that also lights and reflects in every surface, with exponential fog toward the distance.

## Properties

| Field | Default | What it does |
|---|---|---|
| `sky` | Procedural | Procedural, a gradient from the ground through the horizon to the zenith with the sun. Panorama, an equirectangular texture. Color, flat `sky_top`. |
| `sky_top`, `sky_horizon`, `ground` | blue, pale blue, brown | The procedural sky's colours. `sky_top` is also the Color sky. |
| `sun_size` | 1 | The sun disc's angular radius in degrees. The sun is the first enabled directional Light. |
| `panorama` | none | The Panorama sky's image: an `.hdr` is linear light, other images are sRGB. |
| `panorama_rotation` | 0 | Degrees around the vertical. |
| `exposure` | 1 | The sky's brightness. |
| `ambient_intensity` | 1 | How much the sky lights surfaces, diffuse. |
| `reflection_intensity` | 1 | How much surfaces reflect it, specular. |
| `draw_sky` | on | Draws the sky behind the cameras. Off, their clear colour stays. |
| `fog` | Off | The fog below. |

## Fog

| Field | Default | What it does |
|---|---|---|
| `mode` | Off | Off, Exponential, Exponential_Squared or Linear. |
| `color` | pale grey | The fog's colour. |
| `density` | 0.02 | The exponential modes: per world unit. |
| `start`, `end` | 10, 100 | Linear: no fog before `start`, all of it at `end`. |
| `height`, `height_falloff` | 0, 0 | Full density below `height`, falling off above it. 0 falloff is the same fog at every height. |
| `sky` | 0.5 | How much fog the sky takes at the horizon, none straight up. |

## Behavior

- The sky's diffuse and specular light are computed from it on the GPU when it changes, and a [Reflection Probe](ReflectionProbe.md) replaces them inside its box.
