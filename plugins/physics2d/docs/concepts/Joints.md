---
title: "Joints"
description: "How a joint connects the Rigidbody2D on its object to another body or to the world: when it is built, which fields stay live, and how it breaks"
weight: 25
tags: ["physics2d", "joints"]
---

A joint holds the Rigidbody2D on its own object to another body, or to a point in the world. Three components do it: [HingeJoint2D](../components/HingeJoint2D.md) turns about a shared point, [DistanceJoint2D](../components/DistanceJoint2D.md) keeps two anchors apart, [FixedJoint2D](../components/FixedJoint2D.md) holds two bodies as one. The code is `joints.odin`.

```
Chain          Rigidbody2D body_type Static
Link1          Rigidbody2D, BoxCollider2D, HingeJoint2D connected Chain, anchor 0, 0.5
Link2          Rigidbody2D, BoxCollider2D, HingeJoint2D connected Link1, anchor 0, 0.5
```

Each link hangs from the one above it by its top edge.

## The two bodies

- A joint needs a Rigidbody2D on its own object. Without one it does nothing, and the console says so once.
- `connected` picks the other Rigidbody2D. Empty holds the object to the world.
- `enable_collision` lets the two bodies collide with each other. Off by default, so a hinge between two overlapping links does not push them apart.

## When it is built

- The fixed step builds a joint once both bodies exist, from the pose they have at that moment. An anchor is where it is then, and a hinge's angle then is its zero.
- Motor, limit, spring and distance fields reach the live joint every step: game code drives a motor by setting `motor_speed`.
- The anchors, `connected` and `enable_collision` apply when the joint is built. Disabling the component removes the joint, and enabling it builds a new one from the pose of that moment.

## Breaking

- `break_force` and `break_torque`, when above 0, are the force in newtons and the torque in newton-meters the joint can take. A step whose joint force or torque goes above them breaks the joint: it is removed and the component is disabled.
- Game code sees the break as the component's `enabled` turning off. No event fires.

## Angles

Angles are in degrees, and a positive one turns counterclockwise. A hinge's angle, limits and motor are its own object's turn relative to the connected body.
