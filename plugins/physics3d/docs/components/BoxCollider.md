---
title: "BoxCollider"
description: "A box collision shape"
weight: 20
tags: ["physics3d", "components"]
---

A box collision shape. Without a [Rigidbody](Rigidbody.md) on or above its object it is a static collider, with one it is a shape of that body.

## Example

```
Crate      Rigidbody, BoxCollider size 1, 1, 1
Floor      BoxCollider size 20, 0.2, 20
```

The crate falls and lands on the floor. The floor has no Rigidbody, so its box is static.

## Properties

| Field | Default | What it does |
|---|---|---|
| `size` | 1, 1, 1 | The box's size, before the object's scale. |
| `center` | 0, 0, 0 | Where the box's center sits from the object. |
| `density` | 1 | How the body's mass spreads over its colliders: the center of mass and the inertia, in kilograms per cubic metre. |
| `material` | none | The [Physics Material](../assets/PhysicsMaterial.md). None takes the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## In the editor

A selected collider draws its wireframe. In the Handles tool, T, bounds handles resize it. One drag is one undo step.
