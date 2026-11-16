---
title: "FixedJoint"
description: "Holds a body to another or to the world as if they were one, until it breaks"
weight: 90
tags: ["physics3d", "components", "joints"]
---

Holds the Rigidbody on its object to another body, or to the world, so neither moves nor turns relative to the other ([Joints](../concepts/Joints.md)).

## Example

```
Tower          Rigidbody is_kinematic, BoxCollider
Block          Rigidbody, BoxCollider, FixedJoint connected Tower, break_force 2000
```

The block holds to the tower until something hits it hard enough.

## Properties

| Field | Default | What it does |
|---|---|---|
| `connected` | none | The other Rigidbody. None holds the object to the world. |
| `enable_collision` | off | The two bodies collide with each other. |
| `break_force`, `break_torque` | 0 | The force and torque above which the joint breaks. 0 never breaks. |

## In the editor

A selected fixed joint draws a line to its connected body.
