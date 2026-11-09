---
title: "Audio clip"
description: "A .wav, .mp3 or .ogg file, imported to float PCM with its gain baked in, previewed with a waveform"
weight: 10
tags: ["audio", "assets"]
---

A `.wav`, `.mp3` or `.ogg` file. The importer decodes it and bakes its settings into the artifact, so every consumer hears the mastered sound.

## Import settings

Shown in the Project Inspector when the file is selected, applied with Apply.

| Setting | Default | What it does |
|---|---|---|
| `volume` | 1 | The mastering gain, baked into the samples. Per-object volume is AudioSource's `volume`. |
| `normalize` | off | Scales the sound so its peak reaches 1, before `volume` applies. |

## Artifact

- The importer decodes the source to 32-bit float PCM at its own sample rate and channel count, applies `normalize` then `volume`, and writes a float WAV.
- Playback loads the artifact, never the source.
- Changing a setting imports under a new artifact key. Changing it back finds the old artifact again, with no import.
- A reimport drops the loaded clip, so the next play uses the new sound with no restart.

## In the editor

- The Project Inspector's Preview shows the waveform of the artifact, with Play and Stop. Clicking the waveform seeks, and starts playback when stopped. One preview plays at a time, apart from any AudioSource.
- The clip's length, sample rate and channels show under its import settings.
- An audio file drags onto any `ext:"mp3,wav,ogg"` field, such as AudioSource's `clip`.

## From code

```odin
audio.play_clip(guid)                         // a 2D one-shot
audio.play_clip_at_point(guid, {0, 1, 5})     // a spatial one-shot
clip, ok := audio.clip_load(guid)             // the loaded clip, cached by guid
```

## See also

- [Playback](../concepts/Playback.md), one-shots and the clip cache.
