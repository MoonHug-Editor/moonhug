---
title: "TweenRotateLocalTo"
description: "A tween that rotates an object from its rotation at the clip's start to a given rotation"
weight: 60
tags: ["sequencer", "components"]
---

A tween for a [ClipTween](_index.md): rotates its target from its local rotation when the clip starts to `to`, along the shortest arc.

## Properties

| Field | Default | What it does |
|---|---|---|
| `capture` | Play | When the start rotation is taken again: Play once per play session, Enter on every pass into the clip. |
| `target` | none | The object to rotate. Unset, the track's `target`. |
| `to` | 0, 0, 0 | The local rotation at the clip's end, edited as Euler angles. |

## Behavior

- The rotation slerps between the two, so it takes the shortest way and never passes through a third orientation.
- The start rotation is captured the way [TweenMoveLocalTo](TweenMoveLocalTo.md) captures its start position.
