---
title: "Depth of field"
description: "postfx_dof: blurs the scene by each pixel's distance from the focus, through a thin lens on a 24 mm sensor"
weight: 20
tags: ["postfx", "render-steps"]
---

`postfx_dof` blurs the HDR scene by how far each pixel is from the focus, and writes back into `hdr`. Reads `hdr`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `focus_distance` | 10 | The sharp distance, in metres. |
| `focal_length` | 50 | The lens, in millimetres. A longer lens blurs more either side of the focus. |
| `aperture` | 5.6 | The f-number. A lower one blurs more. |
| `max_blur` | 0.03 | The widest blur, as a fraction of the view's height. |
| `samples` | 24 | Taps on each pixel's disc. |

## Behavior

- **Circle of confusion.** A thin lens, from the focal length, the aperture and the focus distance, gives the circle a point at the pixel's depth makes on a 24 mm sensor: negative in front of the focus, positive behind, capped at `max_blur`. It is computed at half size, where each 2 by 2 block averages its colour and keeps its nearest pixel's circle, so a near object keeps its spread.
- **Blur.** Each half-size pixel gathers `samples` taps on a disc, a golden-angle spiral turned per pixel by noise. A tap counts where its own circle, or the pixel's, reaches it: a blurred near object spreads over its sharp neighbours, and a sharp object does not bleed into a blurred one behind it.
- **Combine.** The sharp scene where the circle is under half a pixel, the blur where it is two pixels or more, blended between.
- The sky is at the far plane, so it blurs when the focus is near, as a camera's would.
- A Volume can move the focus per place.
