---
title: "Playback"
description: "How a director advances time and evaluates its tracks: the evaluation modes, crossings, clip weights, track kinds and who ticks a director"
weight: 20
tags: ["sequencer", "concepts"]
---

How a [PlayableDirector](../components/PlayableDirector.md) plays its timeline. The code is `director.odin` and `timeline.odin`.

## Evaluation is a function of time

- Every frame (`@(update)`, order 2) each playing director advances its time by the frame's delta times its speed, wraps or stops at its duration, and evaluates its tracks.
- An evaluation reads the tree into track views (`director_tracks`), builds each track's state the first time, and calls each track kind's `tick` with the time window the playhead moved through.
- What a timeline shows depends on the time alone. Scrubbing is `director_set_time`, the same evaluation at another time, so any time is valid and exact.
- The tree's shape is fingerprinted: adding, removing or reordering track and clip objects, or changing a kind or a clip's asset, rebuilds the tracks' state. Field edits need no rebuild, since the components are the data.

## Modes

Each evaluation has a mode, and each track kind decides what a mode means for what it drives:

| Mode | When | What tracks do |
|---|---|---|
| Play | play mode, the director ticking itself | Crossings fire and side effects are real. |
| Scrub | `director_set_time`, a dragged ruler or a paused preview | Time jumped. Stateful tracks reset and replay to the time. Nothing sounds. |
| Preview_Play | the editor's preview advancing on its own | Crossings fire, so audio plays live. Particles still replay. Scripts stay silent. |

`director_evaluate_at(d, time, mode)` evaluates at an explicit time and mode. A control track forwards its clip's local time to the nested director through it, in the parent's mode.

## Crossings

`track_crossed(ctx, at)` tells a track whether the playhead passed `at` this frame: the half-open window from the previous time to the current one, split in two when a loop wrapped inside the frame. It is never true while scrubbing. Script enter and exit and an audio clip's start use it.

## Clip weight

`track_clip_weight(clips, index, t)` is one rule for every kind:

- A clip weighs 0 outside its span.
- **The overlap is the blend.** Where two clips on a track overlap, the earlier one ramps out across the overlap while the later one ramps in, and the two sum to 1. Dropping a clip on its neighbour's tail crossfades with nothing to author.
- `ease_in` and `ease_out` ramp the weight where no neighbour overlaps, and the longer ramp wins where both apply.
- The weight is derived from the spans and never stored, so it cannot disagree with where the clips sit.

## Track kinds

A kind registers a `Track_Desc` with `track_register` at the `ImportersInit` phase, at order 4 or later so the sequencer's own registration at order 3 runs first:

| Field | What it is |
|---|---|
| `track_key`, `clip_key` | The kind's track and clip components. The track component's type is the registry key. |
| `label`, `color` | Its name in Add Track and its row colour in the Sequencer window. |
| `build`, `destroy` | Make and free the kind's state for one director and track. Optional. |
| `tick` | Evaluate the track. It gets a `Track_Ctx`: the track's view, whose `node` carries the kind's own component, the director's object, the state, the time window, the mode and the play session. |
| `preview_end` | Quiet whatever the track drove when the editor's preview stops: restore a pose, stop a voice, clear particles. |
| `binding_field` | The name of the field on the track component that says what the track drives. A driver's inspector, such as the TimelineAnimator's, draws that field beside the state that plays the timeline. Optional. |

The sequencer imports no kind's package. The activation, control, script and tween kinds register the same way the animation, audio and particles kinds do.

## Who ticks a director

- A director ticks itself while it is enabled, its object is active in the hierarchy, and nothing else owns it.
- A director under a [ClipControl](../components/ClipControl.md) clip belongs to the parent timeline.
- A driver in another package claims directors with `director_register_drive_check(proc(d) -> bool)`. The animation plugin's TimelineAnimator claims the directors its states play.
- `play_id` counts play sessions: `director_play`, a director starting on its own, and a control clip entered during play. Tweens that capture once per session compare it.

## The editor preview

The Sequencer window brackets the scene and game render with `sequencer_preview_apply` and `sequencer_preview_restore`. Apply evaluates at the preview time: `director_preview_step` while the preview plays, `director_set_time` while it is paused or dragged. Restore calls `director_preview_end`, and while the preview plays it keeps what must persist between frames, such as an audio voice.

## See also

- [Timelines as prefabs](TimelinesAsPrefabs.md)
- [Scripts and tweens](ScriptsAndTweens.md)
