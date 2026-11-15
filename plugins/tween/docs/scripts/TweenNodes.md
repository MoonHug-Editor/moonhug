---
title: "Tween nodes"
description: "The stock tween node types: Sequence and Parallel composites, the transform, UI, camera and light value nodes, shake, events, and the easing and cycles every value node has"
weight: 10
tags: ["tween", "scripts"]
---

The node types a tween tree is made of. Every node has these base fields:

| Field | What it does |
|---|---|
| `subject` | The object the node animates. Empty: the object the code passed when it started the tree. Set: this object, whatever the code passed. |
| `delay` | Seconds to wait before the node starts. |
| `skip` | Keeps the node from running. |
| `own_clock`, `clock` | On the tree's root: with `own_clock` on, the tree runs on `clock`. Off: on the clock the code passed. On other nodes they are not read. |

| Node | Fields | What it does |
|---|---|---|
| Sequence | children | Runs its children one after another, and is done after the last. |
| Parallel | children | Runs all its children every tick, and is done when they all are. |
| TweenMoveToLocal | `position`, `duration`, `speed` | Moves the subject's local position from where it is to `position`. |
| TweenScaleToLocal | `scale`, `duration` | Scales the subject from its scale to `scale`. |
| TweenRotateToLocal | `rotation`, `duration` | Rotates the subject from its rotation to `rotation`, edited as Euler angles, along the shortest arc. |
| TweenMoveToWorld | `position`, `duration`, `speed` | Moves the subject's world position to `position`, whatever its parent is. |
| TweenRotateToWorld | `rotation`, `duration` | Rotates the subject to the world rotation `rotation`. |
| TweenAnchoredPosition | `position`, `duration`, `speed` | Moves a UI subject's anchored position: canvas units from its anchors. |
| TweenSizeDelta | `size`, `duration` | Resizes a UI subject: its size delta. |
| TweenUITint | `tint`, `alpha_only`, `duration` | Tints a UI graphic through its CanvasRenderer's runtime tint. With `alpha_only` it fades the graphic and leaves the color. |
| TweenCameraFov | `fov`, `duration` | Changes a camera's field of view. |
| TweenLightIntensity | `intensity`, `duration` | Changes a light's intensity. |
| TweenLightColor | `color`, `duration` | Changes a light's color. |
| TweenShake | `part`, `punch`, `strength`, `frequency`, `duration` | Shakes the subject's position, rotation or scale around where it is, fading out. With `punch` it swings along the strength. |
| TweenEvent | `name` | Calls the run's `on_event` proc with `name`. |

- A value node captures its start when it begins, after its delay. A `duration` of 0 sets the value at once.
- A `speed` above 0 is units per second: the node takes the distance divided by the speed, and its `duration` is ignored.
- A value node ends when its subject is destroyed.
- A new TweenRotateToLocal's `rotation` reads as no rotation until it is set.
- The code that starts a tree passes the default object: `tween.run(&tree, tween.TweenContext{subject = door})`. A node with its own `subject` set in the inspector animates that object, so one tree moves a door and fades its handle.
- A set `subject` is looked up in the scene of the default object when the run starts. One that names no object there stops the whole tree from running, with an error in the log.

## Easing and cycles

Every node in the table except Sequence, Parallel and TweenEvent is a value node. Every value node has these fields on top of its own:

| Field | What it does |
|---|---|
| `ease` | The shape of the motion over one cycle. `Linear` by default. |
| `curve` | The shape when `ease` is `Curve`: a curve from 0 to 1 on both axes. An empty curve is linear. |
| `cycles` | How many times the node plays. 0 and 1 play once, -1 repeats until the run is stopped or completed. |
| `cycle_mode` | What a cycle after the first one does. |

The eases are `Linear`, `Curve`, and the `In`, `Out` and `In_Out` forms of `Quad`, `Cubic`, `Quart`, `Quint`, `Sine`, `Circ`, `Expo`, `Elastic`, `Back` and `Bounce`. `Back` and `Elastic` go past the start or the end on purpose.

| Cycle mode | Every cycle after the first |
|---|---|
| `Restart` | goes from the start to the end again |
| `Yoyo` | every second cycle goes from the end back to the start, eased the same way |
| `Incremental` | starts where the last one ended and moves by the same amount |
| `Rewind` | every second cycle plays the first one backwards |

- A node with `Yoyo` or `Rewind` and an even number of cycles ends at its start value.
- `Incremental` with 3 cycles and a move by 2 ends 6 away from the start.

## Events

A tree cannot hold a proc, so it calls into code by name. A TweenEvent node hands its `name` to the proc the code gave the run:

```odin
h := tween.run(&d.tree, tween.TweenContext{subject = d.owner})
tween.on_event(h, door_event, d)

door_event :: proc(name: string, user: rawptr) {
	d := cast(^Door)user
	switch name {
	case "opened": d.is_open = true
	case "slam":   play_slam(d)
	}
}
```

- A run with no `on_event` proc passes its event nodes without a word.
- `tween.complete` still reaches every event node on the way to the end.
