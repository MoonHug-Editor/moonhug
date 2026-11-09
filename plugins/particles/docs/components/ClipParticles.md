---
title: "ClipParticles"
description: "Makes a timeline clip a particles clip: its span is when the TrackParticles system plays"
weight: 30
tags: ["particles", "sequencer", "components"]
---

Makes a timeline clip a particles clip on a [TrackParticles](TrackParticles.md). Needs the sequencer plugin.

## Example

```
Fireworks               PlayableDirector
└── Sparks              TimelineTrack + TrackParticles, system Sparks
    └── burst           TimelineClip + ClipParticles, 2.5 to 4 s
```

The Sparks system plays from 2.5 to 4 seconds.

## Behavior

- It has no fields: the clip's span is when the track's system plays.
