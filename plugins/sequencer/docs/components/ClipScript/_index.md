---
title: "ClipScript"
description: "A clip on a script track: the list of scripts the clip runs"
weight: 61
tags: ["sequencer", "components"]
---

Makes a clip a script clip: the scripts it runs while playback is inside it ([TrackScript](../TrackScript.md)).

## Example

```
DoorScene               PlayableDirector
└── Events              TimelineTrack + TrackScript
    └── open            TimelineClip + ClipScript, 3 to 5 s
                          ScriptSetActive target Door, active off
                          ScriptLog enter "door opens"
```

From 3 to 5 seconds the door is inactive, and entering the clip logs a line.

## Properties

| Field | Default | What it does |
|---|---|---|
| `scripts` | empty | The scripts, each one variant of `ScriptUnion`. |

## Scripts

The built-in scripts each have a page under this one:

- [ScriptSetActive](ScriptSetActive.md) sets an object active for the span.
- [ScriptLog](ScriptLog.md) logs a message on enter, tick or exit.

Other plugins add their own ([Scripts and tweens](../../concepts/ScriptsAndTweens.md)).

## In the editor

Add an element to `scripts` and pick its type in the element's dropdown. A new element is ScriptNone, which does nothing.
