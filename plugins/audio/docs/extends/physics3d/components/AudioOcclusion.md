---
title: "AudioOcclusion"
description: "A wall between the listener and the AudioSource on its object muffles the source and turns it down"
weight: 40
tags: ["audio", "physics3d", "components"]
---

A wall between the [AudioListener](../../../components/AudioListener.md) and the [AudioSource](../../../components/AudioSource.md) on its object muffles the source and turns it down. Needs the physics3d plugin.

## Example

```
Generator       AudioSource: clip hum.ogg, loop on, spatial_blend 1
                AudioOcclusion: cutoff 800, volume 0.5
```

Behind the wall of the next room, the generator's hum loses its high end and drops to half.

## Properties

| Field | Default | What it does |
|---|---|---|
| `cutoff` | 800 Hz | A fully blocked source keeps what is below it. |
| `volume` | 0.5 | A fully blocked source's volume, as a part of its own. |
| `layers` | all | The physics layers whose colliders block the sound. |
| `speed` | 6 | How fast it follows a change: 1 takes a second from clear to blocked, 6 a sixth. |

## Behavior

- Every frame a ray goes from the listener to the source ([physics3d.raycast](/plugins/physics3d/docs/concepts/Queries.md)). A collider on `layers` in between blocks the sound. The colliders of the listener's object and of the source's object, and those under them, never do. Triggers do not block.
- How blocked the source is moves toward the ray's answer at `speed`, so a sound going behind a wall fades rather than switches.
- Partly blocked, the cutoff falls from 22 kHz toward `cutoff` on a log scale and the volume toward `volume`.
- The muffling runs after the object's [AudioLowPassFilter](../../../components/AudioLowPassFilter.md) and [AudioHighPassFilter](../../../components/AudioHighPassFilter.md).
- Only while the game runs: in the editor the physics world is not built, so the source plays clear.

## Limits

- One straight ray: sound does not bend around a doorway.
- 3D physics only.
