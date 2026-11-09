---
title: "CapsuleCollider"
description: "A capsule collision shape: a cylinder with round ends"
weight: 40
tags: ["physics3d", "components"]
---

A capsule collision shape: a cylinder with round ends. Without a [Rigidbody](Rigidbody.md) on or above its object it is a static collider, with one it is a shape of that body.

## Properties

| Field | Default | What it does |
|---|---|---|
| `radius` | 0.5 | The radius, before the object's scale. |
| `height` | 2 | The total height, round ends included. |
| `direction` | Y_Axis | The axis the capsule runs along: X_Axis, Y_Axis or Z_Axis. |
| `center` | 0, 0, 0 | Where the capsule's center sits from the object. |
| `density` | 1 | How the body's mass spreads over its colliders: the center of mass and the inertia, in kilograms per cubic metre. |
| `material` | none | The [Physics Material](../assets/PhysicsMaterial.md). None takes the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## In the editor

A selected collider draws its wireframe. In the Handles tool, T, handles resize it. One drag is one undo step.
