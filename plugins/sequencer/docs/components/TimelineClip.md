---
title: "TimelineClip"
description: "Makes an object under a track a clip: its span on the timeline, its ease ramps and its speed"
weight: 30
tags: ["sequencer", "components"]
---

Makes an object under a track a clip: its span on the timeline. The kind's clip component beside it holds what the clip plays, such as [ClipScript](ClipScript/_index.md).

## Properties

| Field | Default | What it does |
|---|---|---|
| `start` | 0 | Where the clip starts, in seconds of timeline time. |
| `duration` | 0 | How long the clip lasts. A zero-duration clip is an instant. |
| `ease_in` | 0 | Seconds of weight ramp at the start, where no earlier clip overlaps it. |
| `ease_out` | 0 | Seconds of weight ramp at the end, where no later clip overlaps it. |
| `speed` | 0 | The clip's local time scale. 0 behaves as 1. |

## Behavior

- A clip covers `[start, start + duration)`.
- Clips on one track are ordered by `start`, not by their order in the hierarchy.
- Where two clips on a track overlap, the overlap is a crossfade: the earlier clip ramps out while the later one ramps in, and the two weights sum to 1 ([Playback](../concepts/Playback.md), "Clip weight"). How a kind uses the weight is the kind's choice: audio scales volume, animation blends poses.

## In the editor

In the Sequencer window a clip is a block on its track's row. Drag the body to move it, drag an edge to resize it, both in tenths of a second. The block draws its weight curve, which reads as an X across an overlap.

## See also

- [TimelineTrack](TimelineTrack.md)
