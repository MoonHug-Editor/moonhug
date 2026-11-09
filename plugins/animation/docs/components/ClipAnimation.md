---
title: "ClipAnimation"
description: "The clip of an animation track: which animation clip a timeline clip plays"
weight: 40
tags: ["animation", "sequencer", "components"]
---

Makes a timeline clip an animation clip: it names the clip a [TrackAnimation](TrackAnimation.md) plays for the clip's span. Needs the sequencer plugin.

A timeline clip is an object under a track that carries `TimelineClip`, with its `start`, `duration`, `ease_in`, `ease_out` and `speed`, and the kind's clip component, this one ([Timelines as prefabs](/plugins/sequencer/docs/concepts/TimelinesAsPrefabs.md), "The parts").

## Example

```
Body                    TimelineTrack + TrackAnimation
└── raise               TimelineClip start 0, duration 1.2, ease_out 0.2
                        ClipAnimation clip swing_body.anim
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `clip` | none | The animation clip to play: a `.anim`, or a clip inside a model. |

## Behavior

- Inside its span the clip plays from its own start, scaled by the timeline clip's `speed`.
- Its weight follows the timeline clip's `ease_in` and `ease_out`, so it fades against the clips it overlaps on the same track.
- A clip shorter than the span wraps by the clip's own wrap setting ([Animation clip](../assets/AnimationClip.md)).

## See also

- [TrackAnimation](TrackAnimation.md), the track it belongs to.
- [Animation clip](../assets/AnimationClip.md), what `clip` refers to.
