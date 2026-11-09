---
title: "ClipControl"
description: "A clip on a control track: plays the nested timeline under the clip object"
weight: 51
tags: ["sequencer", "components"]
---

Makes a clip a control clip on a [TrackControl](TrackControl.md): it plays a nested timeline for its span.

## Example

```
Show                    PlayableDirector
└── Acts                TimelineTrack + TrackControl
    └── intro           TimelineClip + ClipControl, 0 to 4 s
        └── Intro       a timeline prefab instance, PlayableDirector
```

The Intro timeline plays for the first four seconds of the show.

## Behavior

- It has no fields: the timeline it plays is the first [PlayableDirector](PlayableDirector.md) among the clip object's children.
