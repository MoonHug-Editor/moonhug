---
title: "TimelineTrack"
description: "Makes an object under a PlayableDirector a track, with a kind component beside it that says what the track drives"
weight: 20
tags: ["sequencer", "components"]
---

Makes an object under a [PlayableDirector](PlayableDirector.md) a track. A track object carries two components: this one, which every track has, and a kind component beside it that says what the track drives, such as [TrackActivation](TrackActivation.md).

## Properties

| Field | Default | What it does |
|---|---|---|
| `muted` | off | A muted track does not evaluate. |

## Behavior

- The object's name is the track's name, and the order of the director's children is the order of the tracks.
- The kind component decides how the track plays. It holds the track's target and options, and its type is what the track kind registry looks up, so there is no kind field to keep in step.
- A track without a kind component, or with a kind no installed plugin registers, does nothing.

## In the editor

The Sequencer window's legend shows each track with its mute toggle and name. Right-click the name for Add Clip at Playhead, Rename and Remove Track.

## See also

- [TimelineClip](TimelineClip.md), what each clip on the track has.
- [Timelines as prefabs](../concepts/TimelinesAsPrefabs.md)
