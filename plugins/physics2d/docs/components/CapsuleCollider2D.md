---
title: "CapsuleCollider2D"
description: "A capsule collision shape: a rectangle with round ends"
weight: 40
tags: ["physics2d", "components"]
---

A capsule collision shape: a rectangle with round ends. Without a [Rigidbody2D](Rigidbody2D.md) on or above its object it is a static collider, with one it is a shape of that body.

## Example

```
Player     Rigidbody2D fixed_rotation on, CapsuleCollider2D size 0.8, 1.8
```

A character body. The round ends slide over steps and seams, and the fixed rotation keeps it upright.

## Properties

| Field | Default | What it does |
|---|---|---|
| `size` | 1, 2 | Width and height, round ends included, before the object's scale. |
| `direction` | Vertical | Which way the capsule runs: Vertical or Horizontal. |
| `offset` | 0, 0 | Where the capsule's center sits from the object. |
| `density` | 1 | How the body's mass spreads over its colliders, in kilograms per square metre. Decides the mass when the Rigidbody2D's `use_auto_mass` is on. |
| `material` | none | The [Physics Material 2D](../assets/PhysicsMaterial2D.md). None takes the Rigidbody2D's, then the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## In the editor

A selected collider draws its outline. In the Handles tool, T, a bounds handle resizes it. One drag is one undo step.
