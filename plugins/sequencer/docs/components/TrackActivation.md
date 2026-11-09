---
title: "TrackActivation"
description: "An activation track: its target is active while any clip covers the time and inactive otherwise"
weight: 40
tags: ["sequencer", "components"]
---

Makes a track an activation track: its target object is active while any of its clips covers the time, and inactive otherwise. Its clips carry [ClipActivation](ClipActivation.md).

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The object to switch, in the same file. |

## Behavior

- The track writes the target's active state on every evaluation, so scrubbing shows it exactly.
- In the editor's preview the track remembers the target's state before the preview and puts it back when the preview stops, so an object authored inactive stays inactive.

## See also

- [ScriptSetActive](ClipScript/ScriptSetActive.md), the same switch as one step of a script clip.
