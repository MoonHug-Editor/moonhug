---
title: "HingeJoint"
description: "Holds a body to another or to the world at a pivot, turning about an axis through it, with limits and a motor"
weight: 70
tags: ["physics3d", "components", "joints"]
---

Holds the Rigidbody on its object to another body, or to the world, at a pivot both share. The body turns about an axis through the pivot ([Joints](../concepts/Joints.md)).

## Example

```
Door           Rigidbody, BoxCollider size 1, 2, 0.1, HingeJoint anchor -0.5, 0, 0, axis 0, 1, 0, use_limits, lower_angle -90, upper_angle 0
Fan            Rigidbody, BoxCollider size 2, 0.1, 0.3, HingeJoint axis 0, 0, 1, use_motor, motor_speed 180
```

The door turns about a vertical axis through its left edge, a quarter turn at most. The fan spins about its forward axis, half a turn a second.

## Properties

| Field | Default | What it does |
|---|---|---|
| `connected` | none | The other Rigidbody. None holds the object to the world. |
| `anchor` | 0, 0, 0 | The pivot, in the object's own space. |
| `axis` | 1, 0, 0 | The axis the body turns about, in the object's own space. |
| `enable_collision` | off | The two bodies collide with each other. |
| `use_limits` | off | Keeps the turn between `lower_angle` and `upper_angle`. |
| `lower_angle`, `upper_angle` | -90, 90 | The turn allowed each way, in degrees from the angle at which the joint was built. |
| `use_motor` | off | Turns the body at `motor_speed`. |
| `motor_speed` | 0 | Degrees per second, counterclockwise seen from where the axis points. |
| `max_motor_torque` | 10000 | The most torque the motor applies, in newton-meters. |
| `break_force`, `break_torque` | 0 | The force and torque above which the joint breaks. 0 never breaks. |

## In the editor

A selected hinge draws a ring at its pivot around the axis, an arrow along the axis, and a line to its connected body.
