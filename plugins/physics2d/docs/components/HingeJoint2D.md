---
title: "HingeJoint2D"
description: "Holds a 2D body to another or to the world at a pivot it turns about, with limits and a motor"
weight: 70
tags: ["physics2d", "components", "joints"]
---

Holds the Rigidbody2D on its object to another body, or to the world, at a pivot both share. The body turns about it ([Joints](../concepts/Joints.md)).

## Example

```
Door           Rigidbody2D, BoxCollider2D size 1, 2, HingeJoint2D anchor -0.5, 0, use_limits, lower_angle -90, upper_angle 0
Wheel          Rigidbody2D, CircleCollider2D, HingeJoint2D connected Cart, use_motor, motor_speed -360
```

The door turns about its left edge, a quarter turn clockwise at most. The wheel turns about its center on the cart, one turn a second clockwise.

## Properties

| Field | Default | What it does |
|---|---|---|
| `connected` | none | The other Rigidbody2D. None holds the object to the world. |
| `anchor` | 0, 0 | The pivot, in the object's own space. |
| `enable_collision` | off | The two bodies collide with each other. |
| `use_limits` | off | Keeps the turn between `lower_angle` and `upper_angle`. |
| `lower_angle`, `upper_angle` | -90, 90 | The turn allowed each way, in degrees from the angle at which the joint was built. |
| `use_motor` | off | Turns the body at `motor_speed`. |
| `motor_speed` | 0 | Degrees per second, counterclockwise. |
| `max_motor_torque` | 10000 | The most torque the motor applies, in newton-meters. |
| `break_force`, `break_torque` | 0 | The force and torque above which the joint breaks. 0 never breaks. |

## In the editor

A selected hinge draws a ring at its pivot and a line to its connected body.
