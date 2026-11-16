---
title: "FixedJoint2D"
description: "Holds a 2D body to another or to the world as if they were one, until it breaks"
weight: 90
tags: ["physics2d", "components", "joints"]
---

Holds the Rigidbody2D on its object to another body, or to the world, so neither moves nor turns relative to the other ([Joints](../concepts/Joints.md)).

## Example

```
Wall           Rigidbody2D, BoxCollider2D
Brick          Rigidbody2D, BoxCollider2D, FixedJoint2D connected Wall, break_force 500
```

The brick holds to the wall until something hits it hard enough.

## Properties

| Field | Default | What it does |
|---|---|---|
| `connected` | none | The other Rigidbody2D. None holds the object to the world. |
| `enable_collision` | off | The two bodies collide with each other. |
| `break_force`, `break_torque` | 0 | The force and torque above which the joint breaks. 0 never breaks. |

## In the editor

A selected fixed joint draws a line to its connected body.
