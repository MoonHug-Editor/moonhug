---
title: "Motion blur"
description: "postfx_motion_blur: smears each pixel along how far it moved since last frame, with the camera and with moving objects"
weight: 10
tags: ["postfx", "render-steps"]
---

`postfx_motion_blur` smears each pixel of the HDR scene along how far it moved on screen since last frame, and writes back into `hdr`. Reads `hdr` and, when present, `motion`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `intensity` | 0.5 | How much of each frame's motion the blur spans: a shutter open for half the frame. |
| `samples` | 8 | Taps along the motion. |
| `max_blur` | 0.05 | The longest blur, as a fraction of the view's height. |
| `camera` | on | Blurs with the camera's motion too. Off, only moving objects blur. |

## Behavior

- An object that moved carries its motion vector where the engine's `motion_vectors` step drew it. That step runs with or without `scene_taa`.
- Everything else moved with the camera: the pixel's depth reprojected through last frame's camera, which the step keeps per view. A view that skipped a frame or changed size blurs only its moving objects that frame.
- The blur spans `intensity` of the motion, centred on the pixel, in `samples` taps offset per pixel by noise so the steps do not band. Pixels that moved less than half a pixel stay as they are.
- Each pixel gathers along its own motion only: a moving object blurs inside its silhouette and does not smear over what is behind it, and a still object in front of a moving background keeps its edge.
- The motion is per frame as drawn, not per second: a higher frame rate shows less blur at the same speed, as a camera with the same shutter share would.
