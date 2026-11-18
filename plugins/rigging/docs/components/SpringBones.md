---
title: "SpringBones"
description: "Makes a chain of bones lag behind its root and swing back: hair, tails, capes, antennas"
weight: 20
tags: ["rigging", "components"]
---

Makes a chain of bones lag behind its root and swing back. Hair, a tail, ears, a cape or an antenna move with the character with nothing animated by hand.

## Example

```
Head               SpringBoneCollider radius 0.12
└── Ponytail 1     SpringBones stiffness 1, drag 0.4, gravity 0, -1, 0, colliders Head
    └── Ponytail 2
        └── Ponytail 3
            └── Ponytail End
```

While the game runs the three ponytail bones swing as the head moves and stay out of the head's sphere. Ponytail End has no child: it marks where the last bone ends and only follows.

## Properties

| Field | Default | What it does |
|---|---|---|
| `root` | none | The chain's first bone. None is this object. |
| `stiffness` | 1 | How hard a bone returns to its pose. 0 leaves it to inertia and gravity. |
| `drag` | 0.4 | The part of its motion a bone loses each frame. 0 swings for long, 1 does not swing. |
| `gravity` | 0, 0, 0 | A steady pull, in world units per second. |
| `radius` | 0.02 | The size of a bone's end against the colliders. |
| `colliders` | none | An object: the chain stays out of every [SpringBoneCollider](SpringBoneCollider.md) on it or under it. |

## Behavior

- Every bone under `root` that has a child swings, branches included. A bone points at its first child, so the next bone of the chain goes before any other child, such as a mesh.
- A bone with no child is the end of a chain. It does not swing itself.
- The bones keep their lengths and positions. Only rotations change.
- The pose the bones return to is the one they have when the game starts. When animation or code writes a bone's rotation, that rotation is the pose to return to from then on.
- The chain runs in the late update while the game runs, after animation and after [TwoBoneIK](TwoBoneIK.md).
- Selected, it draws each swinging bone with a sphere of `radius` at its end, and its colliders.

## Tuning

- A stiff antenna: `stiffness` 3 or more, `drag` 0.3.
- Loose hair or a cape: `stiffness` under 1, `gravity` pointing down, `drag` around 0.2.
- A chain that never settles has too little `drag`. One that looks frozen has too much, or too much `stiffness`.
