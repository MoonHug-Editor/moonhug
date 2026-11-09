---
title: "ClipActivation"
description: "A clip on an activation track: its span is when the target is active"
weight: 41
tags: ["sequencer", "components"]
---

Makes a clip an activation clip on a [TrackActivation](TrackActivation.md).

## Example

```
Show                    PlayableDirector
└── Banner              TimelineTrack + TrackActivation, target Banner
    └── shown           TimelineClip + ClipActivation, 1 to 3 s
```

The banner is active from 1 to 3 seconds.

## Behavior

- It has no fields: the clip's span is the instruction.
- The track's target is active while any of its clips covers the time, and inactive otherwise.
