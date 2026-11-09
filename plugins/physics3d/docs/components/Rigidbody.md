---
title: "Rigidbody"
description: "Makes an object a dynamic or kinematic 3D body, with mass, gravity, damping and per-axis freezes"
weight: 10
tags: ["physics3d", "components"]
---

Makes its object a dynamic or kinematic body. The colliders on it and below it are the body's shapes. A collider with no Rigidbody on or above it is static ([Bodies](../concepts/Bodies.md)).

## Example

```
Car            Rigidbody mass 1200, BoxCollider size 2, 0.8, 4.5
└── Cabin      BoxCollider size 1.8, 0.7, 2, center 0, 0.7, -0.3
Door           Rigidbody is_kinematic on, BoxCollider size 1, 2, 0.1
```

The car is one dynamic body with two shapes, its own box and the cabin's. The door moves by code or animation and pushes what it meets.

## Properties

| Field | Default | What it does |
|---|---|---|
| `mass` | 1 | The body's mass in kilograms. The colliders' density only spreads it: the center of mass and the inertia. |
| `use_gravity` | on | The world's gravity pulls the body. |
| `is_kinematic` | off | Moves only by code or animation, pushes dynamic bodies and is never pushed. |
| `linear_damping` | 0 | Slows the body's movement over time. |
| `angular_damping` | 0 | Slows the body's spin over time. |
| `continuous` | off | Continuous collision detection, so a fast body does not pass through thin colliders. |
| `freeze_position` | none | Locks movement along each world axis. |
| `freeze_rotation` | none | Locks rotation around each axis. |
| `include`, `exclude` | none | Layers every collider of this body also collides with, or never collides with ([Collision layers](../concepts/CollisionLayers.md)). Drawn inline, from `layer_overrides`. |

## Behavior

- The body is built when play starts, from the object's transform and the colliders on it and below it.
- Each fixed step a dynamic body writes its position and rotation back to the transform. A kinematic body goes the other way: it moves to wherever code or animation put its transform, and pushes the dynamic bodies in its path.
- A body carries convex shapes only: boxes, spheres, capsules, and convex MeshColliders.
