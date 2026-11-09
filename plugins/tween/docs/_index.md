---
title: "tween"
description: "Tween trees: authored as values in component fields, run as live node trees, with sequence and parallel composites and node types any plugin adds"
tags: ["tween", "plugin"]
---

The tween plugin moves, scales and rotates objects over time with tween trees. A tree is authored as one value in a component field, so saving, undo, prefab overrides and copy and paste treat it like any field. Running it makes a live tree of pooled nodes that ticks until it is done. Node types register at runtime, so any plugin adds its own.

These tweens run on their own clock. For poses driven by a timeline's playhead, the sequencer plugin has its own clip tweens ([Scripts and tweens](/plugins/sequencer/docs/concepts/ScriptsAndTweens.md)).

## What it adds

**Components**

- [TweenPlayer](components/TweenPlayer.md) holds a list of authored tween trees on an object.

**Scripts**

- [Tween nodes](scripts/TweenNodes.md): Sequence, Parallel, and the move, scale and rotate leaves.

**Windows**

- [Tween Graph](windows/TweenGraphWindow.md): a tree on a canvas, edited node by node.

**Concepts**

- [Authored and live trees](concepts/AuthoredAndLive.md): the two forms of a tree, running one, and adding node types.

## What it needs

- The engine plugin.

## Quick start

```odin
import tween "moonhug:packages/tween"

a := tween.authored(tween.Sequence{}, {
	tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}, duration = 0.5}),
	tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}, duration = 0.5}),
})
defer tween.authored_destroy(&a)
tween.tween_run(&a, tween.TweenContext{subject = cube})
```

The app ticks running trees every frame with `tween_tick_running`.

## Extending

The plugin declares no attributes. A node type registers with `register_node` from a `SerializationInit` phase proc, from any plugin, and appears in every type picker ([Authored and live trees](concepts/AuthoredAndLive.md), "Adding a node type"). `plugins/plugin_example/tween_spinner.odin` is the reference.

## Limits

- Three leaves: move, scale and rotate in local space, linear in time. No easing curves yet.

## Reference

- [API reference](/docs/reference/packages/tween/tween.md) of the `tween` package.
