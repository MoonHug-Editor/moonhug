---
title: "PlayableDirector"
description: "Plays the timeline under its object: track objects as children, clip objects under them"
weight: 10
tags: ["sequencer", "components"]
---

Plays the timeline made of the objects under it: each child with a [TimelineTrack](TimelineTrack.md) is a track, and each child of a track with a [TimelineClip](TimelineClip.md) is one of its clips.

## Example

```
Fireworks               PlayableDirector, wrap Once
├── Rocket              TimelineTrack + TrackActivation, target Rocket
│   └── flight          TimelineClip + ClipActivation, 0 to 2.5 s
└── Bang                TimelineTrack + TrackScript, target Rocket
    └── explode         TimelineClip + ClipScript, at 2.5 s, duration 0
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `wrap` | Once | Once stops at the end and holds there. Loop starts again from 0. |
| `speed` | 0 | Playback speed. 0 plays at 1. |
| `manual_start` | off | Off plays the timeline on its own when the scene starts. On waits for `director_play`. |
| `duration` | 0 | The timeline's length in seconds. 0 takes the end of the last clip. |

## Behavior

- Every frame, an enabled director whose object is active advances its time and evaluates every track ([Playback](../concepts/Playback.md)).
- A director under a [ClipControl](ClipControl.md) clip never ticks itself: the parent timeline sets its time. A director that another component claims, a TimelineAnimator state for instance, does not tick itself either.
- Each play session counts up `play_id`: `director_play`, the start of a director without `manual_start`, and a control clip entered during play. Tweens that capture once per session read it.
- Adding, removing or reordering track and clip objects rebuilds the tracks on the next evaluation. Field edits apply at once, since the components are the timeline's data.

## In the editor

- The [Sequencer window](../windows/SequencerWindow.md) edits the timeline of the selected director and previews it without entering play mode.
- The hierarchy and the inspector work on the track and clip objects like on any other object.

## From code

```odin
import seq "moonhug:packages/sequencer"

_, d := engine.transform_get_comp(fireworks, seq.PlayableDirector)
seq.director_play(d)            // from the current time
seq.director_pause(d)
seq.director_stop(d)            // back to 0
seq.director_set_time(d, 1.5)   // jump and evaluate, no crossings fire
```

## See also

- [Timelines as prefabs](../concepts/TimelinesAsPrefabs.md)
- [Playback](../concepts/Playback.md)
