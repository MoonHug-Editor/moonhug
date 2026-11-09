---
title: "Physics Material 2D"
description: "How a 2D surface slides and bounces: friction, bounciness and how each combines with the other collider's"
weight: 10
tags: ["physics2d", "assets"]
---

How a surface slides and bounces. Assets, Create, Physics Material 2D makes one.

## Fields

| Field | Default | What it does |
|---|---|---|
| `friction` | 0.4 | How much the surface resists sliding. box2d uses one coefficient for sliding and resting. |
| `bounciness` | 0 | How much speed a bounce keeps, 0 to 1. |
| `friction_combine` | Mean | How this friction combines with the other collider's. |
| `bounce_combine` | Maximum | How this bounciness combines with the other collider's. |

The combine modes are Average, Mean (the geometric mean, `sqrt(a * b)`), Multiply, Minimum and Maximum. When two colliders' modes differ, the higher-ranked one wins: Maximum, then Minimum, Multiply, Mean and Average. The defaults, Mean for friction and Maximum for bounciness, are how box2d mixes them on its own.

## Which material a collider uses

1. The collider's own `material`.
2. Else the `material` of the [Rigidbody2D](../components/Rigidbody2D.md) it attaches to, so one body sets the material of all its colliders.
3. Else the project's Default Material, in the Physics 2D settings.
4. Else a new material's defaults.

## In the editor

A collider's `material` field has a foldout that edits the asset in place. An edit, in the inspector or on disk, reaches the colliders that use the material on the next physics step, also while the game runs and before it is saved.
