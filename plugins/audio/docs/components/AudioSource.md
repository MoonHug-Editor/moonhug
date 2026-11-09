---
title: "AudioSource"
description: "Plays an audio clip on its object, 2D or spatialized against the AudioListener"
weight: 10
tags: ["audio", "components"]
---

Plays an [audio clip](../assets/AudioClip.md) on its object, in 2D or spatialized against the [AudioListener](AudioListener.md).

## Example

A torch on the wall that crackles in 3D:

```
Torch           AudioSource: clip fire_loop.ogg, loop on, spatial_blend 1, max_distance 20
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `clip` | none | The audio file to play: `.mp3`, `.wav` or `.ogg`. |
| `volume` | 1 | This source's volume, on top of the gain baked into the clip. |
| `pitch` | 1 | The playback speed ratio. 2 plays an octave up and twice as fast. |
| `mute` | off | Silences the source without stopping it. |
| `loop` | off | Starts the clip again when it ends. |
| `play_on_awake` | on | Plays when the scene starts and when the source is enabled again. |
| `spatial_blend` | 0 | 0 plays in 2D, centered at full volume. 1 fades and pans against the listener. Between, the two mix. |
| `min_distance` | 1 | Full volume inside this radius. |
| `max_distance` | 500 | The fade stops falling past this radius. |

## Behavior

- Each playing source has its own track in the mixer, made the first time it plays and freed with the component.
- Volume, pitch, mute and the spatial fade and pan apply every frame, so inspector edits are audible live.
- Disabling a source stops it. Enabling it again replays it when `play_on_awake` is on.
- Sources play in play mode in the editor and always in a game. Leaving play mode stops them all.
- A reimport of the clip, after its settings change, restarts a `play_on_awake` source with the new sound.

## In the editor

- The inspector has Play and Stop buttons, to hear the source without entering play mode.
- A selected source shows `min_distance` and `max_distance` as wire spheres. In the Handles tool, T, each sphere has a radius handle. Dragging the min past the max pushes the max out with it.
- Every source shows a speaker icon in the Scene window.

## From code

```odin
import "moonhug:packages/audio"

_, src := engine.transform_get_comp(torch, audio.AudioSource)
audio.audio_play(src, fade_in_ms = 200)
if audio.audio_is_playing(src) do audio.audio_stop(src, fade_out_ms = 500)
```

## Limits

- No priority, no Doppler and no output group.

## See also

- [Playback](../concepts/Playback.md), how sources, one-shots and spatial sound work.
