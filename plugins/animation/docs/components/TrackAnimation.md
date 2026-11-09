---
title: "TrackAnimation"
description: "A timeline track that plays animation clips on an Animation component"
weight: 30
tags: ["animation", "sequencer", "components"]
---

Makes a timeline track an animation track: its clips play on an [Animation](Animation.md) component, and overlapping clips cross-fade. Needs the sequencer plugin.

A track is an object under a timeline's PlayableDirector that carries `TimelineTrack` and one kind component, this one ([Sequencer](/plugins/sequencer/docs/Sequencer.md), "Structure"). Its clips are the objects under it that carry [ClipAnimation](ClipAnimation.md).

## Example

```
swing                   PlayableDirector
├── Body                TimelineTrack + TrackAnimation, target Hero/Body
│   └── raise           TimelineClip + ClipAnimation, clip swing_body.anim
└── Prop                TimelineTrack + TrackAnimation, target Hero/Sword
    └── slash           TimelineClip + ClipAnimation, clip swing_sword.anim
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The Animation component the clips play on, an object in the same file. Unset, the track uses an Animation on the director's own object, and poses the director's transform directly when there is none. |

## Behavior

- The track drives its target, and the target's own playback stands down while it does (`Animation.timeline_driven`), so the two never write the same transforms in one frame. The track hands it back when it stops driving, at the end of a preview or on a retarget.
- Each clip of the track is a clip node on the track's mixer. Its weight comes from the clip's ease ramps, so two overlapping clips cross-fade.
- A source clip shorter than its timeline clip wraps by its own wrap setting.
- Clips may animate component fields as well as transforms ([Clip format](../concepts/ClipFormat.md)).
- Every animation track of one director builds into one playable graph, with one output per object the tracks target. Two tracks aimed at one object stack instead of one replacing the other.
- Under a [TimelineAnimator](TimelineAnimator.md) the track builds into the animator's graph instead, and the animator writes the pose. The track's `target` stays the only binding.

## In the editor

- The Sequencer window shows the track and its clips, and scrubbing poses the target.
- A TimelineAnimator's inspector shows `target` under the state that plays the timeline. Editing it there edits this field.

## Limits

- Retargeting a timeline to another character is a prefab override on `target`. There is no binding table.

## See also

- [ClipAnimation](ClipAnimation.md), the clips this track plays.
- [Playback levels](../concepts/PlaybackLevels.md), how the track stacks over the Animation it drives and under a TimelineAnimator.
