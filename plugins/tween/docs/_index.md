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

- [Tween nodes](scripts/TweenNodes.md): Sequence, Parallel, the transform, UI, camera and light value nodes, shake, events, and their easing and cycles.

**Windows**

- [Tween Graph](windows/TweenGraphWindow.md): a tree on a canvas, edited node by node and previewed in edit mode.
- [Tweens](windows/TweensWindow.md): every running tween, with pause, complete and stop.

**Concepts**

- [Tweens from code](concepts/TweensFromCode.md): one-line tweens for transforms, UI, cameras and lights, any component field, any value through a proc, shake and punch, delays and sequences built step by step.
- [Authored and live trees](concepts/AuthoredAndLive.md): the two forms of a tree, and adding node types.
- [Runs](concepts/Runs.md): the handle of a running tree, its controls, clocks, rewind and binding to an object.

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

## Sample

The `tween_sample` package (`plugins/tween/samples/tween_sample`) is a field of cubes in `tween_demo.scene`. Open the scene and press Play, pick it from the demo menu, or run the package's run config.

Every cube carries the script that moves it, configured in the inspector: select a cube to see what it does and with which numbers. The same script is on every cube it fits, and only its data differs. The scripts are in `tween_demo.odin`, a few lines each.

| Cube | Script | Its data says |
|---|---|---|
| Red row | DemoTween | move up by 2, Yoyo forever. Each cube has another ease: Linear, Quad In Out, Back In Out, Bounce Out, Elastic Out, Expo In Out |
| Spin | DemoTween | turn by 120 degrees, Incremental forever: a turn that keeps going |
| Pulse | DemoTween | scale to 1.5, Yoyo forever |
| Hop Unscaled | DemoTween | the hop on the `Unscaled` clock. Press T for slow motion: it keeps its speed |
| Patrol | DemoTween | a world-space move at a speed in place of a duration |
| Punch | DemoTweenShake | a punch of the scale, every 1.5 seconds |
| Shake | DemoTweenShake | a shake of the position, every 2 seconds |
| Orbit | DemoTweenOrbit | `custom`: an angle written as a place on a circle |
| Sequence | DemoTweenSequence | `sequence`, `chain`, `group` and `chain_delay`, restarted from its completion |
| Tree, Tree Other | DemoTweenTree | an authored tree. The script runs it on its own cube, two nodes name Tree Other as their subject, and the last one is an authored shake |

- Timing is a `tween.Settings` field on the script, so the duration, the ease and the cycles are set per cube.
- A script that repeats binds its run to its cube, so the run stops with the cube.
- DemoTweenControls on the scene's root toggles slow motion with T.

## Extending

The plugin declares no attributes. A node type registers with `register_tween` or `register_node` from a `SerializationInit` phase proc, from any plugin, and appears in every type picker ([Authored and live trees](concepts/AuthoredAndLive.md), "Adding a node type"). `plugins/plugin_example/tween_spinner.odin` is the reference.

## Limits

- Easing and cycles belong to value nodes. A sequence plays once.
- A step that ends hands over to the next one in the same tick, and the next one gets the whole tick, so a sequence can run a fraction of a tick long.
- The eases have fixed shapes. Overshoot, bounce and elastic take no strength.
- An authored tree calls code by name through TweenEvent. It holds no proc, so `custom`, `field`, callbacks and wait-until steps are made from code.
- No material property tween: a material is a shared asset with no per-object properties, so a tween would change every object that uses it.
- A speed-based tween reports no useful progress, since its length is known only when it begins.
- The sprite and audio tweens are one-line calls. A tree does not author them.

## Reference

- [API reference](/docs/reference/packages/tween/tween.md) of the `tween` package.
