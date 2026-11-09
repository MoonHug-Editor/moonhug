---
title: "AudioListener"
description: "The ear: spatial sources fade and pan against the first enabled listener's transform"
weight: 20
tags: ["audio", "components"]
---

The ear. Spatial sources fade with distance and pan left and right against the first enabled AudioListener's transform. It usually sits on the camera.

## Example

```
Main Camera    Camera, AudioListener
Campfire       AudioSource clip Fire.ogg, loop on, spatial_blend 1
```

The campfire gets quieter as the camera moves away from it, and pans left or right as the camera turns.

## Properties

None: its object's transform is the data.

## Behavior

- The first enabled listener with a valid object is the ear. Others are ignored.
- Without a listener every source plays in 2D, whatever its `spatial_blend`.

## See also

- [Playback](../concepts/Playback.md), "Spatial sound".
