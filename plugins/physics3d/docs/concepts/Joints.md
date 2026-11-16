---
title: "Joints"
description: "How a joint connects the Rigidbody on its object to another body or to the world: when it is built, which fields stay live, and how it breaks"
weight: 25
tags: ["physics3d", "joints"]
---

A joint holds the Rigidbody on its own object to another body, or to a point in the world. Three components do it: [HingeJoint](../components/HingeJoint.md) turns about an axis through a shared point, [DistanceJoint](../components/DistanceJoint.md) keeps two anchors apart, [FixedJoint](../components/FixedJoint.md) holds two bodies as one. The code is `joints.odin`.

```
Frame          Rigidbody is_kinematic, BoxCollider
Door           Rigidbody, BoxCollider size 1, 2, 0.1, HingeJoint connected Frame, anchor -0.5, 0, 0, axis 0, 1, 0
```

The door turns about a vertical axis through its left edge, on the frame.

## The two bodies

- A joint needs a Rigidbody on its own object. Without one it does nothing, and the console says so once.
- `connected` picks the other Rigidbody. Empty holds the object to the world.
- `enable_collision` lets the two bodies collide with each other. Off by default, so a hinge between two overlapping parts does not push them apart.

## When it is built

- The fixed step builds a joint once both bodies exist, from the pose they have at that moment. An anchor is where it is then, and a hinge's angle then is its zero.
- Motor, limit, spring and distance fields reach the live joint every step: game code drives a motor by setting `motor_speed`.
- The anchors, the axis, `connected` and `enable_collision` apply when the joint is built. Disabling the component removes the joint, and enabling it builds a new one from the pose of that moment.

## Breaking

- `break_force` and `break_torque`, when above 0, are the force in newtons and the torque in newton-meters the joint can take. A step whose joint force or torque goes above them breaks the joint: it is removed and the component is disabled.
- Game code sees the break as the component's `enabled` turning off. No event fires.

## Angles

Angles are in degrees. A hinge's angle, limits and motor are its own object's turn about the axis relative to the connected body, positive counterclockwise seen from where the axis points.
