---
title: "TweenMoveLocalTo"
description: "A tween that moves an object's local position from where it is at the clip's start to a given point"
weight: 40
tags: ["sequencer", "components"]
---

A tween for a [ClipTween](_index.md): moves its target's local position in a straight line from where it is when the clip starts to `to`.

## Properties

| Field | Default | What it does |
|---|---|---|
| `capture` | Play | When the start position is taken again: Play once per play session, Enter on every pass into the clip. |
| `target` | none | The object to move. Unset, the track's `target`. |
| `to` | 0, 0, 0 | The local position at the clip's end. |

## Behavior

- The start position is captured the first time the tween evaluates ([TrackTween](../TrackTween.md)). With Play a looping timeline replays the same motion, with Enter each pass continues from where the object is.
- When the editor's preview stops, the object returns to the captured start.
