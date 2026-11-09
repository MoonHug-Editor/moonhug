---
title: "TrackControl"
description: "A control track: each clip plays the nested timeline under it"
weight: 50
tags: ["sequencer", "components"]
---

Makes a track a control track: each of its clips plays a nested timeline, the first [PlayableDirector](PlayableDirector.md) among the clip object's children. Its clips carry [ClipControl](ClipControl.md). It has no fields, since each clip's own children are what it plays.

## Example

```
Show                    PlayableDirector
└── Acts                TimelineTrack + TrackControl
    ├── intro           TimelineClip + ClipControl, 0 to 4 s
    │   └── Intro       a timeline prefab instance, PlayableDirector
    └── finale          TimelineClip + ClipControl, 4 to 9 s
        └── Finale      a timeline prefab instance, PlayableDirector
```

## Behavior

- Inside a clip's span the nested director evaluates at the clip's local time, scaled by the clip's `speed`, in the parent's mode. Outside it the nested director rests at 0, quietly.
- A nested director never ticks itself and never sees `director_play`. Entering its clip during play starts a new play session for it.
- A nested timeline is usually a prefab instance, so the same timeline plays in several places and each instance can override its targets.
