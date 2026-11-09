---
title: "audio"
description: "Sound: audio clips with baked gain, the AudioSource and AudioListener components, one-shots, spatial sound and a timeline track"
tags: ["audio", "plugin"]
---

The audio plugin plays sound. An audio file is imported into a clip with its gain baked in, an AudioSource plays a clip on an object, an AudioListener is the ear that spatial sources pan and fade against, and code fires one-shots with no component at all. The backend is SDL3_mixer.

## What it adds

**Components**

- [AudioSource](components/AudioSource.md) plays a clip on its object, 2D or spatial.
- [AudioListener](components/AudioListener.md) is the ear, usually on the camera.
- [TrackAudio](components/TrackAudio.md) and [ClipAudio](components/ClipAudio.md) play clips on a timeline. Need the sequencer plugin.

**Assets**

- [Audio clip](assets/AudioClip.md): a `.wav`, `.mp3` or `.ogg` file, with its import settings and a waveform preview.

**Concepts**

- [Playback](concepts/Playback.md): the mixer, the tracks, one-shots, play mode and spatial sound.

[Roadmap](Roadmap.md): what is not built yet.

## What it needs

- The engine plugin.
- SDL3_mixer, the `vendor:sdl3/mixer` library: `brew install sdl3_mixer` on macOS.
- Optional, the sequencer plugin. It adds TrackAudio and ClipAudio, which play clips on a timeline. They live in the plugin's `sequencer` subpackage, which builds only when the sequencer plugin is enabled ([Plugins](/docs/core/Plugins.md)).

## Quick start

1. Drop a `.wav`, `.mp3` or `.ogg` file into the project.
2. Add Component, Audio/AudioSource on any object, and drag the file onto its `clip` field.
3. Press Play. `play_on_awake` is on, so the clip plays as the scene starts.

To hear it without play mode, press the source's Play button in the inspector, or select the file and press Play in the Project Inspector's Preview.

## Extending

The plugin declares no attributes and has no registries. Code uses it through its procs: `audio_play`, `audio_stop` and `play_clip_at_point` among them ([AudioSource](components/AudioSource.md), [Playback](concepts/Playback.md)).

## Limits

- Clips decode whole into memory when they load. There is no streaming.
- No mixer groups and no effects.
- One listener: the first enabled one. No Doppler and no reverb zones.

## Reference

- [API reference](/docs/reference/packages/audio/audio.md) of the `audio` package, and of its [sequencer integration](/docs/reference/packages/audio/sequencer.md).
