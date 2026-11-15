---
title: "tween"
description: "Tweens started from code with one call or authored as trees in component fields, with a handle to stop, complete and pause a run, easing, cycles, timelines, sequences and node types any plugin adds"
tags: ["tween", "plugin"]
---

The tween plugin moves, scales and rotates objects and animates any value over time. A tween is started from code with one call, or authored as a tree: one value in a component field, so saving, undo, prefab overrides and copy and paste treat it like any field. Either way it runs as a live tree of pooled nodes behind a handle that stops, completes, pauses and speeds up the run. Node types register at runtime, so any plugin adds its own.

A run ticks on one of the engine's timelines ([Time](/plugins/engine/docs/Time.md)). For poses driven by a timeline's playhead, the sequencer plugin has its own clip tweens ([Scripts and tweens](/plugins/sequencer/docs/concepts/ScriptsAndTweens.md)).

## What it adds

**Components**

- [TweenPlayer](components/TweenPlayer.md) holds a list of authored tween trees on an object.

**Scripts**

- [Tween nodes](scripts/TweenNodes.md): Sequence, Parallel, the move, scale and rotate value nodes, and their easing and cycles.

**Windows**

- [Tween Graph](windows/TweenGraphWindow.md): a tree on a canvas, edited node by node.

**Concepts**

- [Tweens from code](concepts/TweensFromCode.md): one-line tweens, any value through a proc, delays and sequences built step by step.
- [Authored and live trees](concepts/AuthoredAndLive.md): the two forms of a tree, and adding node types.
- [Runs](concepts/Runs.md): the handle of a running tree, its controls, timelines and binding to an object.

## What it needs

- The engine plugin.

## Quick start

From code:

```odin
import tween "moonhug:packages/tween"

h := tween.position(cube, {1, 0, 0}, 0.5, .Back_Out)
tween.on_complete(h, proc(user: rawptr) { /* the move is done */ })

s := tween.sequence()
tween.chain(s, tween.scale(cube, {2, 2, 2}, 0.5))
tween.chain_delay(s, 1)
tween.chain(s, tween.scale(cube, {1, 1, 1}, 0.5))
tween.stop(s)   // or tween.complete, tween.set_paused
```

Authored:

```odin
a := tween.authored(tween.Sequence{}, {
	tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}, duration = 0.5}),
	tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}, duration = 0.5}),
})
defer tween.authored_destroy(&a)

h := tween.run(&a, tween.TweenContext{subject = cube})
```

The plugin ticks its runs itself, every frame and every fixed tick.

## Extending

The plugin declares no attributes. A node type registers with `register_tween` or `register_node` from a `SerializationInit` phase proc, from any plugin, and appears in every type picker ([Authored and live trees](concepts/AuthoredAndLive.md), "Adding a node type"). `plugins/plugin_example/tween_spinner.odin` is the reference.

## Limits

- Three transform tweens: move, scale and rotate in local space. Everything else goes through `tween.custom`.
- Easing and cycles belong to value nodes. A sequence plays once.
- Time a node has left over when it ends is dropped, so a sequence's next step starts on the next tick.
- An authored tree does not name its timeline. `tween.run` takes it.
- The eases have fixed shapes. Overshoot, bounce and elastic take no strength.
- A callback is a proc and a pointer. Authored trees have no callback node.

## Reference

- [API reference](/docs/reference/packages/tween/tween.md) of the `tween` package.
