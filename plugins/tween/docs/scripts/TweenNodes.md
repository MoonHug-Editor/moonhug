---
title: "Tween nodes"
description: "The stock tween node types: Sequence and Parallel composites, the move, scale and rotate value nodes, and the easing and cycles every value node has"
weight: 10
tags: ["tween", "scripts"]
---

The node types a tween tree is made of. Every node has the base fields `delay`, seconds to wait before it starts, and `skip`, which keeps it from running.

| Node | Fields | What it does |
|---|---|---|
| Sequence | children | Runs its children one after another, and is done after the last. |
| Parallel | children | Runs all its children every tick, and is done when they all are. |
| TweenMoveToLocal | `position`, `duration` | Moves the subject's local position from where it is to `position`. |
| TweenScaleToLocal | `scale`, `duration` | Scales the subject from its scale to `scale`. |
| TweenRotateToLocal | `rotation`, `duration` | Rotates the subject from its rotation to `rotation`, edited as Euler angles, along the shortest arc. |

- A value node captures its start when it begins, after its delay. A `duration` of 0 sets the value at once.
- A new TweenRotateToLocal's `rotation` reads as no rotation until it is set.
- The subject is the `TweenContext`'s, given to `tween.run`.

## Easing and cycles

Move, scale and rotate are value nodes. Every value node has these fields on top of its own:

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
