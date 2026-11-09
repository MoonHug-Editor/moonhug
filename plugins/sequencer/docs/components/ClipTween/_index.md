---
title: "ClipTween"
description: "A clip on a tween track: the list of tweens the clip's span drives"
weight: 71
tags: ["sequencer", "components"]
---

Makes a clip a tween clip: the tweens its span drives ([TrackTween](../TrackTween.md)). Several tweens on one clip play in parallel, and consecutive clips play in sequence.

## Properties

| Field | Default | What it does |
|---|---|---|
| `tweens` | empty | The tweens, each one variant of `TweenUnion`. |

## Tweens

The built-in tweens each have a page under this one:

- [TweenMoveLocalFromTo](TweenMoveLocalFromTo.md) moves between two given points.
- [TweenMoveLocalTo](TweenMoveLocalTo.md) moves from where the object is to a point.
- [TweenScaleLocalTo](TweenScaleLocalTo.md) scales from the current scale to a scale.
- [TweenRotateLocalTo](TweenRotateLocalTo.md) rotates from the current rotation to a rotation.

Other plugins add their own, such as the sprites plugin's [TweenFadeTo](/plugins/sprites/docs/scripts/TweenFadeTo.md) ([Scripts and tweens](../../concepts/ScriptsAndTweens.md)).

## In the editor

Add an element to `tweens` and pick its type in the element's dropdown. A new element is TweenNone, which does nothing.
