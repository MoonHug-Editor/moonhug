---
title: "sequencer"
description: "Timelines: a director plays tracks of clips laid out in time, and a timeline is a prefab"
tags: ["sequencer", "plugin"]
---

The sequencer plugin plays timelines. A timeline is an object with a PlayableDirector, track objects under it and clip objects under those, so a timeline saved as a prefab is reused, overridden and nested the way any prefab is. Tracks switch objects on and off, play nested timelines, run scripts and pose objects with tweens. Other plugins add their own track kinds.

## What it adds

**Components**

- [PlayableDirector](components/PlayableDirector.md) plays the timeline under it.
- [TimelineTrack](components/TimelineTrack.md) and [TimelineClip](components/TimelineClip.md): what every track and every clip has.
- [TrackActivation](components/TrackActivation.md) and [ClipActivation](components/ClipActivation.md): an object is active while a clip covers the time.
- [TrackControl](components/TrackControl.md) and [ClipControl](components/ClipControl.md): a clip plays the nested timeline under it.
- [TrackScript](components/TrackScript.md) and [ClipScript](components/ClipScript/_index.md): a clip runs scripts when playback enters, stays in and leaves it. The built-in scripts are pages under ClipScript.
- [TrackTween](components/TrackTween.md) and [ClipTween](components/ClipTween/_index.md): a clip poses objects as a function of the playhead. The built-in tweens are pages under ClipTween.

**Windows**

- [Sequencer](windows/SequencerWindow.md): edits the timeline of the selected object and previews it in edit mode.

**Guides**

- [Making a timeline](guides/MakingATimeline.md)

**Concepts**

- [Timelines as prefabs](concepts/TimelinesAsPrefabs.md): what a timeline is made of and why it is scene content.
- [Playback](concepts/Playback.md): the director's time, the evaluation modes, crossings and clip blending.
- [Scripts and tweens](concepts/ScriptsAndTweens.md): the variant unions and how a plugin adds a variant.

[Roadmap](Roadmap.md): what is open and what is not planned.

## What it needs

- The engine plugin.

## Quick start

1. Create an empty object and add Playables/PlayableDirector.
2. Open Window, Animation, Sequencer with the object selected.
3. Add Track, activation. Pick the object to switch in the TrackActivation's `target`.
4. Double-click the track's row in the canvas to add a clip, and drag it where the object should be active.
5. Turn on Preview and drag the ruler to scrub, or press Play.

## Extending

The plugin declares no attributes. Code extends it in three ways:

- **Track kinds.** A plugin registers a kind with `track_register(Track_Desc)` at its `ImportersInit` phase: the kind's track and clip components, a label, a colour and hooks that build, tick and quiet the track. The kind lives in the plugin's `sequencer` integration subpackage, so the plugin builds without the sequencer ([Playback](concepts/Playback.md), "Track kinds").
- **Script and tween variants.** A struct that embeds `Clip_Script` or `Clip_Tween` from `sequencer/core`, with its procs in the same file, joins `ScriptUnion` or `TweenUnion` on the next prebuild. No registration call ([Scripts and tweens](concepts/ScriptsAndTweens.md)).
- **Drivers.** A component that owns a director's time registers `director_register_drive_check`, and the director stops ticking itself while the check claims it ([Playback](concepts/Playback.md), "Who ticks a director").

## Limits

- No markers or signals. A zero-duration script clip is the instant event.
- No recording into a timeline.
- No timeline asset of its own: a timeline is scene content or a prefab.
- A clip snaps to tenths of a second when dragged in the window.

## Reference

- [API reference](/docs/reference/packages/sequencer/sequencer.md) of the `sequencer` package, and of [sequencer/core](/docs/reference/packages/sequencer/core.md), [sequencer/scripts](/docs/reference/packages/sequencer/scripts.md) and [sequencer/tweens](/docs/reference/packages/sequencer/tweens.md).
- Samples: `timeline_sample` in the animation plugin, with a fireworks timeline (`timeline_demo.scene`) and timelines played as animation states.
