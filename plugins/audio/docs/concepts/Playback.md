---
title: "Playback"
description: "How sound plays: the mixer and its tracks, one-shots, play mode, headless runs and spatial sound"
weight: 10
tags: ["audio", "concepts"]
---

How the plugin plays sound. The code is `playback.odin`, `clip.odin` and `spatial.odin`.

## The mixer and its tracks

- One SDL3_mixer mixer. A built game opens its playback device at engine start (`EngineInit`), so the first sound does not wait for the device. The editor opens it when Play starts, so a session without Play starts and quits without it (about 190 ms to open and 150 ms to close). Anything else opens it on first use: the first clip load or sound. Each playing [AudioSource](../components/AudioSource.md) owns one track on it, and each one-shot gets a track of its own.
- `clip_load(guid)` loads a clip's artifact once and caches it by guid, the way the engine caches textures. A missing artifact is imported on demand.
- Every frame (`@(update)`) the plugin finds the listener, starts `play_on_awake` sources, applies each playing source's volume, pitch, mute, fade and pan, and frees finished one-shots. It runs in play mode in the editor and always in a game.
- Leaving play mode stops every source and clears every one-shot.

## Headless runs

Tests and tools have no audio device. The mixer then falls back to one with no device: clips load and decode, and nothing is audible. `audio_force_deviceless` forces that mode.

## One-shots

Sounds with no component to own them:

- `play_clip(guid, volume := 1)` plays in 2D.
- `play_clip_at_point(guid, position, volume := 1)` plays fully spatial at a world position, with distances 1 and 500, and keeps panning as the listener moves.

Each one-shot is freed when it ends.

## Spatial sound

The [AudioListener](../components/AudioListener.md) is the ear. A source with `spatial_blend` above 0 fades and pans against it every frame:

- **Fade.** Full volume inside `min_distance`, then `min_distance / distance`, held constant past `max_distance`.
- **Pan.** Left and right balance from the source's direction in the listener's horizontal plane. Height fades the sound but does not pan it.
- **Blend.** `spatial_blend` mixes both effects between 2D at 0 and fully spatial at 1.

`spatial_gains` is the math as a plain proc, so the tests check it without a device. Without a listener every source plays in 2D.

## Timeline voices

The sequencer's [TrackAudio](../components/TrackAudio.md) plays each clip on a voice of its own with `voice_start`, and writes the source's settings onto it with `source_apply_gains` and the clip's weight. That is the same proc a source's own track goes through, so a timeline voice sounds like the source it names.
