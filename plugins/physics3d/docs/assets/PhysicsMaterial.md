---
title: "Physics Material"
description: "How a 3D surface slides and bounces: friction, bounciness and how each combines with the other collider's"
weight: 10
tags: ["physics3d", "assets"]
---

How a surface slides and bounces. Assets, Create, Physics Material makes one.

## Fields

| Field | Default | What it does |
|---|---|---|
| `friction` | 0.6 | How much the surface resists sliding. box3d uses one coefficient for sliding and resting. |
| `bounciness` | 0 | How much speed a bounce keeps, 0 to 1. |
| `friction_combine` | Average | How this friction combines with the other collider's. |
| `bounce_combine` | Average | How this bounciness combines with the other collider's. |

The combine modes are Average, Minimum, Multiply and Maximum. When two colliders' modes differ, the higher-ranked one wins: Maximum, then Multiply, Minimum and Average.

## Which material a collider uses

1. The collider's own `material`.
2. Else the project's Default Material, in the Physics 3D settings.
3. Else a new material's defaults.

## In the editor

A collider's `material` field has a foldout that edits the asset in place. An edit, in the inspector or on disk, reaches the colliders that use the material on the next physics step, also while the game runs and before it is saved.
