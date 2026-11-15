---
title: "Audio tweens"
description: "One-line tweens of an AudioSource's volume and pitch, from code"
weight: 10
tags: ["audio", "tween", "scripts"]
---

One-line tweens of an [AudioSource](../../../../components/AudioSource.md), from the plugin's `tween` subpackage. Needs the tween plugin.

## Example

```odin
import audio_tween "moonhug:packages/audio/tween"

audio_tween.volume(music, 0, 2)              // fade out over two seconds
audio_tween.pitch(engine_sound, 1.5, 0.3)    // rev up
```

## Calls

| Call | Animates |
|---|---|
| `audio_tween.volume(object, to, timing, ease, opt)` | the AudioSource's `volume` |
| `audio_tween.pitch(object, to, timing, ease, opt)` | the AudioSource's `pitch`, its playback frequency ratio |

- `timing` is seconds or a `tween.Settings`, and `ease` and `opt` work as for every one-line tween ([Tweens from code](/plugins/tween/docs/concepts/TweensFromCode.md)).
- Each returns a `tween.Handle`.
- The tween starts from the source's current value, and ends when the AudioSource or its object goes.

## See also

- [API reference](/docs/reference/packages/audio/tween.md) of the `audio/tween` package, `volume` and `pitch` with links to the code.
