---
title: "Rigidbody2D"
description: "Makes an object a simulated 2D body: dynamic, kinematic or static, with mass, gravity scale and damping"
weight: 10
tags: ["physics2d", "components"]
---

Makes its object a simulated body. The colliders on it and below it are the body's shapes ([Bodies](../concepts/Bodies.md)).

## Properties

| Field | Default | What it does |
|---|---|---|
| `body_type` | Dynamic | Dynamic is fully simulated. Kinematic moves only by code or animation, pushes dynamic bodies and is never pushed. Static never moves. |
| `use_auto_mass` | off | On, the colliders' density decides the mass. Off, `mass` does, and the density only spreads it: the center of mass and the inertia. |
| `mass` | 1 | The body's mass in kilograms, when `use_auto_mass` is off. |
| `gravity_scale` | 1 | How much of the world's gravity this body feels. |
| `linear_damping` | 0 | Slows the body's movement over time. |
| `angular_damping` | 0 | Slows the body's spin over time. |
| `fixed_rotation` | off | The body never turns. |
| `continuous` | off | Continuous collision detection, so a fast body does not pass through thin colliders. |
| `material` | none | The [Physics Material 2D](../assets/PhysicsMaterial2D.md) of every collider on this body that names none. |
| `include`, `exclude` | none | Layers every collider of this body also collides with, or never collides with ([Collision layers](../concepts/CollisionLayers.md)). Drawn inline, from `layer_overrides`. |

## Behavior

- The body is built when play starts, from the object's transform and the colliders on it and below it.
- Each fixed step a dynamic body writes its position and rotation back to the transform. A kinematic body goes the other way: it moves to wherever code or animation put its transform, and pushes the dynamic bodies in its path.
