---
title: "Tween nodes"
description: "The stock tween node types: Sequence and Parallel composites, and move, scale and rotate leaves"
weight: 10
tags: ["tween", "scripts"]
---

The node types a tween tree is made of. Every node has the base fields `delay`, seconds to wait before it starts, and `skip`, which keeps it from running.

| Node | Fields | What it does |
|---|---|---|
| Sequence | children | Runs its children one after another, and is done after the last. |
| Parallel | children | Runs all its children every frame, and is done when they all are. |
| TweenMoveToLocal | `position`, `duration` | Moves the subject's local position from where it is to `position`. |
| TweenScaleToLocal | `scale`, `duration` | Scales the subject from its scale to `scale`. |
| TweenRotateToLocal | `rotation`, `duration` | Rotates the subject from its rotation to `rotation`, edited as Euler angles, along the shortest arc. |

- A leaf captures its start on its first frame. A `duration` of 0 sets the value at once.
- A new TweenRotateToLocal's `rotation` reads as no rotation until it is set.
- The subject is the `TweenContext`'s, given to `tween_run`.
