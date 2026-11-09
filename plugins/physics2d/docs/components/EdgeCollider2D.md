---
title: "EdgeCollider2D"
description: "An open line of points, for ground: two-sided segments, or a one-sided smooth chain"
weight: 60
tags: ["physics2d", "components"]
---

An open line of points, for ground outlines. It has no inside and no mass.

## Example

```
Terrain    EdgeCollider2D points (10, 0) (4, 1) (-4, 1) (-10, 0), two_sided off
```

A one-sided hill line for a ground outline. The points run from right to left, so the solid side faces up.

## Properties

| Field | Default | What it does |
|---|---|---|
| `points` | -0.5, 0 to 0.5, 0 | The line, around `offset`, before the object's scale. |
| `offset` | 0, 0 | Where the line's origin sits from the object. |
| `two_sided` | on | On, each edge is a segment that stops a body from either side. Off, the line is a smooth, one-sided chain. |
| `material` | none | The [Physics Material 2D](../assets/PhysicsMaterial2D.md). None takes the Rigidbody2D's, then the project's default. |
| `layers` | layer 0 | The collision layers this collider is on ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## Behavior

- **One-sided chain.** With `two_sided` off, a body sliding along the line never catches on a corner. The solid side is to the right of the path's direction, so a floor's points run from right to left, and a body behind the line passes through. Each end continues straight, so a body sliding off is not caught on it.
- It cannot be a trigger.

## In the editor

In the Handles tool, T, the points are dots to drag, a press on an edge inserts a point, and Alt+click deletes one, down to two points. Each is one undo step.
