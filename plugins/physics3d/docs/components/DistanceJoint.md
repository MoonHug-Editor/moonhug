---
title: "DistanceJoint"
description: "Keeps an anchor on a body at a distance from another body or a point in the world: a rod, a rope or a spring"
weight: 80
tags: ["physics3d", "components", "joints"]
---

Keeps an anchor on the Rigidbody on its object at a distance from an anchor on another body, or from a point in the world ([Joints](../concepts/Joints.md)).

## Example

```
Lamp           Rigidbody, SphereCollider, DistanceJoint connected_anchor 0, 5, 0
Crate          Rigidbody, BoxCollider, DistanceJoint connected Crane, auto_distance off, distance 4, max_distance_only
```

The lamp swings on a rigid rod from the world point 0, 5, 0. The crate hangs from the crane on a rope of 4.

## Properties

| Field | Default | What it does |
|---|---|---|
| `connected` | none | The other Rigidbody. None holds the object to a point in the world. |
| `anchor` | 0, 0, 0 | The anchor on this object, in its own space. |
| `connected_anchor` | 0, 0, 0 | The anchor on the other body, in its object's own space, or a world point when there is none. |
| `auto_distance` | on | The distance is the anchors' when the joint is built. |
| `distance` | 1 | The distance to keep, when `auto_distance` is off. |
| `max_distance_only` | off | A rope: the anchors may come closer, never farther apart. |
| `spring_frequency` | 0 | How stiffly the distance springs back, in hertz. 0 is a rigid rod. |
| `damping_ratio` | 0 | How fast the spring stops swinging: 0 never, 1 without overshooting. |
| `enable_collision` | off | The two bodies collide with each other. |
| `break_force` | 0 | The force above which the joint breaks. 0 never breaks. |

## In the editor

A selected distance joint draws its two anchors and the line between them.
