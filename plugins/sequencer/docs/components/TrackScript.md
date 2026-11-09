---
title: "TrackScript"
description: "A script track: each clip runs scripts as playback enters, stays in and leaves its span"
weight: 60
tags: ["sequencer", "components"]
---

Makes a track a script track: each clip runs the scripts listed on its [ClipScript](ClipScript/_index.md) as playback enters, stays in and leaves the clip's span.

## Example

```
LevelStart              PlayableDirector
└── Events              TimelineTrack + TrackScript
    └── hint            TimelineClip + ClipScript, 0 to 4 s
                          ScriptSetActive target HintPanel, active on
```

The hint panel is active for the first four seconds of the level.

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The track's subject, passed to every script as `ctx.target`. Each script decides whether to use it: ScriptSetActive uses its own `target`. |

## Behavior

- **Enter** runs when playback crosses into a span, **tick** every frame inside it and **exit** when playback leaves it.
- A zero-duration clip is an instant: enter and exit run together on the frame that passes over it, and tick never runs.
- Scripts run in play mode only. Scrubbing and the editor's preview never call them, since a script is game code with real side effects.

## See also

- [ClipScript](ClipScript/_index.md), the scripts a clip runs.
- [Scripts and tweens](../concepts/ScriptsAndTweens.md), how to write one.
