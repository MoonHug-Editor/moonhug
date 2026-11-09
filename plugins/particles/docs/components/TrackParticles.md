---
title: "TrackParticles"
description: "Makes a timeline track a particles track: each clip's span plays a ParticleSystem, and scrubbing replays it exactly"
weight: 20
tags: ["particles", "sequencer", "components"]
---

Makes a timeline track a particles track: each clip's span plays a [ParticleSystem](ParticleSystem.md). Its clips carry [ClipParticles](ClipParticles.md). Needs the sequencer plugin.

## Example

```
Fireworks               PlayableDirector
└── Sparks              TimelineTrack + TrackParticles, system Sparks
    └── burst           TimelineClip + ClipParticles, 2.5 to 4 s
```

The Sparks system plays from 2.5 to 4 seconds, and scrubbing the timeline shows the same particles every time.

## Properties

| Field | Default | What it does |
|---|---|---|
| `system` | none | The ParticleSystem the clips play. |

## Behavior

- Entering a clip plays the system. Leaving it stops the system and clears its live particles, so the clip is the effect's lifetime and play mode shows what scrubbing to the same time shows.
- Scrubbing replays: the system resets and advances in fixed steps to the clip's local time, exact with a `random_seed`. Its sub-emitter targets reset with it.
- When the Sequencer window's preview stops, the system and its sub-emitter targets clear.
- Author a track-driven system with `manual_start` on and a `random_seed`, so the clips decide when it plays and scrubbing shows the same frames every time.

## See also

- [Sequencer](/plugins/sequencer/docs/_index.md), timelines and their other track kinds.
