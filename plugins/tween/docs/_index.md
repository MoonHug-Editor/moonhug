---
title: "tween"
description: "Tweens started from code with one call or authored as trees in component fields, with a handle to stop, complete and pause a run, easing, cycles, clocks, sequences and node types any plugin adds"
tags: ["tween", "plugin"]
---

The tween plugin animates transforms, UI, cameras, lights, any component field and any value over time, with shake and punch on top. A tween is started from code with one call, or authored as a tree: one value in a component field, so saving, undo, prefab overrides and copy and paste treat it like any field. Either way it runs as a live tree of pooled nodes behind a handle that stops, completes, pauses and speeds up the run. Node types register at runtime, so any plugin adds its own.

A run ticks on one of the game's clocks ([Time](/docs/core/Time.md)). For poses driven by a clock's playhead, the sequencer plugin has its own clip tweens ([Scripts and tweens](/plugins/sequencer/docs/concepts/ScriptsAndTweens.md)).

## What it adds

**Components**

- [TweenPlayer](components/TweenPlayer.md) holds a list of authored tween trees on an object.

**Scripts**

- [Tween nodes](scripts/TweenNodes.md): Sequence, Parallel, the transform and UI value nodes, and their easing and cycles.

**Windows**

- [Tween Graph](windows/TweenGraphWindow.md): a tree on a canvas, edited node by node.

**Concepts**

- [Tweens from code](concepts/TweensFromCode.md): one-line tweens for transforms, UI, cameras and lights, any component field, any value through a proc, shake and punch, delays and sequences built step by step.
- [Authored and live trees](concepts/AuthoredAndLive.md): the two forms of a tree, and adding node types.
- [Runs](concepts/Runs.md): the handle of a running tree, its controls, clocks and binding to an object.

## What it needs

- The engine plugin.
- The sprites and audio plugins bring their own one-line tweens, in their `tween` subpackages, when they are enabled next to this one.

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

## Demo

`plugins/app/assets/demo_tweens/demo_tweens.scene` shows the plugin on a field of cubes, and `plugins/app/component_TweenDemo.odin` is the code behind it. Open the scene and press Play, or pick it from the demo menu.

| Cubes | Show |
|---|---|
| Red row | the same hop with six eases: Linear, Quad In Out, Back In Out, Bounce Out, Elastic Out, Expo In Out |
| Spin | Incremental cycles: a turn that keeps going |
| Pulse | a scale that goes out and back forever |
| Punch, Shake | `punch_scale` and `shake_position`, repeated by a bound `delay` |
| Unscaled | a tween on the `Unscaled` clock. Press T for slow motion: it keeps its speed |
| Orbit | `custom`: an angle written as a place on a circle |
| Sequence | `sequence`, `chain`, `group` and `chain_delay`, restarted from its completion |
| Speed | `world_position` with the speed option |
| Tree Actor, Tree Other | an authored tree. The code starts it on Tree Actor, and one node names Tree Other as its own subject |

The hop and the spin read their timing from `tween.Settings` fields on the TweenDemo component, so the inspector changes them.

## Extending

The plugin declares no attributes. A node type registers with `register_tween` or `register_node` from a `SerializationInit` phase proc, from any plugin, and appears in every type picker ([Authored and live trees](concepts/AuthoredAndLive.md), "Adding a node type"). `plugins/plugin_example/tween_spinner.odin` is the reference.

## Limits

- Easing and cycles belong to value nodes. A sequence plays once.
- Time a node has left over when it ends is dropped, so a sequence's next step starts on the next tick.
- An authored tree does not name its clock. `tween.run` takes it.
- The eases have fixed shapes. Overshoot, bounce and elastic take no strength.
- A callback is a proc and a pointer. Authored trees have no callback node.
- Field tweens, shakes and punches are made from code. A tree authors the transform and UI layout nodes.
- No material property tween: a material is a shared asset with no per-object properties, so a tween would change every object that uses it.
- A speed-based tween reports no useful progress, since its length is known only when it begins.

## Reference

- [API reference](/docs/reference/packages/tween/tween.md) of the `tween` package.
