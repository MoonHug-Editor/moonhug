---
title: "TrackTween"
description: "A tween track: each clip's span drives its tweens, posing objects as a function of the playhead"
weight: 70
tags: ["sequencer", "components"]
---

Makes a track a tween track: each clip's span drives the tweens on its [ClipTween](ClipTween/_index.md), posing objects as a function of the playhead.

## Example

```
Intro                   PlayableDirector
└── Camera              TimelineTrack + TrackTween, target Main Camera
    └── dolly           TimelineClip + ClipTween, 0 to 5 s
                          TweenMoveLocalTo to 0, 2, -6
```

The camera moves to its framing over five seconds, posed by the playhead, so scrubbing shows each point of the move.

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The default subject for the track's tweens. A tween with a target of its own poses that instead. |

## Behavior

- A tween's pose depends only on where the playhead is in its clip, from 0 at the start to 1 at the end. Play, scrubbing and the editor's preview all show the same pose at the same time.
- In the editor the timeline owns the pose everywhere: before a clip it shows the start pose, after it the end pose.
- In play mode the game owns an object outside the spans. A clip poses its object inside its span and once more at its end on the way out, and never touches the object before the span starts.
- A tween that moves to a value captures its start when it first evaluates. `capture` decides when that start is taken again: Play once per play session, so a loop replays the same motion, Enter on every pass into the span, so each pass continues from where the object is.
- When the preview stops, the track puts every captured start pose back and forgets the captures.

## See also

- [ClipTween](ClipTween/_index.md), the tweens a clip drives.
- [Scripts and tweens](../concepts/ScriptsAndTweens.md), how to write one.
