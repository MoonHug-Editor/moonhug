---
title: "TwoBoneIK"
description: "Turns the two bones of a limb so its end reaches a target: a hand on a handle, a foot on a step"
weight: 10
tags: ["rigging", "components"]
---

Turns the two bones of a limb so the limb's end reaches a target. The limb is three joints: the root (a shoulder, a hip), the middle (an elbow, a knee) and the tip (a hand, a foot).

## Example

```
Character          Animation, TwoBoneIK tip hand_r, target Handle, hint Elbow Hint
└── Armature
    └── ... upperarm_r
            └── lowerarm_r
                └── hand_r
Handle
Elbow Hint
```

While the game runs the right hand stays on Handle, wherever the animation would put it. The elbow points toward Elbow Hint.

## Properties

| Field | Default | What it does |
|---|---|---|
| `tip` | none | The limb's end: a hand, a foot. |
| `mid` | none | The middle joint. None is the tip's parent. |
| `root` | none | The first joint. None is the middle joint's parent. |
| `target` | none | The object the tip goes to. None leaves the pose alone. |
| `hint` | none | The object the middle joint bends toward. None keeps the side the limb is already bent to. |
| `weight` | 1 | 0 is the pose as it was, 1 the solved pose, between is a blend. |
| `match_rotation` | off | On, the tip also takes the target's rotation. |

## Behavior

- The two bones keep their lengths. Only the root's and the middle joint's rotations change, and the tip's with `match_rotation`.
- A target further away than the limb is long leaves the limb straight toward it.
- The solve runs in the late update while the game runs, after animation. The animation writes the pose again next frame, so `weight` 0 gives the animated pose back at once.
- The component can sit on any object. The character's root is the usual place.
- Selected, it draws the two bones, a line from the tip to the target and a dashed line from the middle joint to the hint.

## From code

```odin
import "moonhug:packages/rigging"

// Let go of the handle over a quarter of a second.
_, ik := engine.transform_get_comp(character, rigging.TwoBoneIK)
ik.weight = max(ik.weight - dt * 4, 0)

// Solve now, for a target moved after the late update.
rigging.two_bone_apply(ik)
```

`rigging.two_bone_solve` is the solve on bare points, for code with its own joints.
