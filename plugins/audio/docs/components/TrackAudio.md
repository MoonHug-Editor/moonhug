---
title: "TrackAudio"
description: "Makes a timeline track an audio track: its clips play through an AudioSource's settings"
weight: 30
tags: ["audio", "sequencer", "components"]
---

Makes a timeline track an audio track: its clips play sounds through an [AudioSource](AudioSource.md)'s settings. Its clips carry [ClipAudio](ClipAudio.md). Needs the sequencer plugin.

## Properties

| Field | Default | What it does |
|---|---|---|
| `source` | none | The AudioSource whose volume, pitch, spatial blend and mute the clips play with. |

## Behavior

- Each playing clip has a voice of its own, never the source's own track, which game code keeps for `audio_play`.
- A clip's weight is its volume: two overlapping clips crossfade, and a clip's `ease_in` and `ease_out` are volume fades.
- The sound follows the playhead. Entering a clip part-way, by pressing Play inside it, playing after a scrub, or a loop wrapping into it, starts the voice at the clip's local offset. Crossing a clip's start restarts it.
- Scrubbing is silent. The Sequencer window's preview plays sound while it plays, and the voices stop when the preview stops.
- Author a track-driven source with `play_on_awake` off, so the clips decide when it plays.

## See also

- [Sequencer](/plugins/sequencer/docs/_index.md), timelines and their other track kinds.
