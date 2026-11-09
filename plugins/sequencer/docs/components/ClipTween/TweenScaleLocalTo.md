---
title: "TweenScaleLocalTo"
description: "A tween that scales an object from its scale at the clip's start to a given scale"
weight: 50
tags: ["sequencer", "components"]
---

A tween for a [ClipTween](_index.md): scales its target linearly from its local scale when the clip starts to `to`.

## Properties

| Field | Default | What it does |
|---|---|---|
| `capture` | Play | When the start scale is taken again: Play once per play session, Enter on every pass into the clip. |
| `target` | none | The object to scale. Unset, the track's `target`. |
| `to` | 0, 0, 0 | The local scale at the clip's end. |

## Behavior

The start scale is captured the way [TweenMoveLocalTo](TweenMoveLocalTo.md) captures its start position.
