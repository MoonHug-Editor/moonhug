---
title: "TweenMoveLocalFromTo"
description: "A tween that moves an object's local position from one given point to another over its clip"
weight: 30
tags: ["sequencer", "components"]
---

A tween for a [ClipTween](_index.md): moves its target's local position from `from` to `to` in a straight line over the clip.

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The object to move. Unset, the track's `target`. |
| `from` | 0, 0, 0 | The local position at the clip's start. |
| `to` | 0, 0, 0 | The local position at the clip's end. |

## Behavior

- Both ends are given, so it captures nothing and `capture` has no effect: every pass and every scrub shows the same motion.
- Use [TweenMoveLocalTo](TweenMoveLocalTo.md) to start from wherever the object is.
