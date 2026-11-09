---
title: "CircleCollider2D"
description: "A circle collision shape"
weight: 30
tags: ["physics2d", "components"]
---

A circle collision shape. Without a [Rigidbody2D](Rigidbody2D.md) on or above its object it is a static collider, with one it is a shape of that body.

## Example

```
Ball       Rigidbody2D, CircleCollider2D radius 0.25, material Bouncy
Coin       CircleCollider2D radius 0.3, is_trigger on
```

The ball rolls and bounces. The coin is a trigger: bodies pass through it and its object gets trigger callbacks.

## Properties

| Field | Default | What it does |
|---|---|---|
| `radius` | 0.5 | The radius, before the object's scale. |
| `offset` | 0, 0 | Where the circle's center sits from the object. |
| `density` | 1 | How the body's mass spreads over its colliders, in kilograms per square metre. Decides the mass when the Rigidbody2D's `use_auto_mass` is on. |
| `material` | none | The [Physics Material 2D](../assets/PhysicsMaterial2D.md). None takes the Rigidbody2D's, then the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## In the editor

A selected collider draws its outline. In the Handles tool, T, a handle resizes it. One drag is one undo step.
