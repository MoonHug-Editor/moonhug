---
title: "SpringBoneCollider"
description: "A sphere a SpringBones chain stays out of: a head for hair, a body for a cape"
weight: 30
tags: ["rigging", "components"]
---

A sphere a [SpringBones](SpringBones.md) chain stays out of. It keeps hair out of a head and a cape out of a body.

## Example

```
Character          
├── Head           SpringBoneCollider radius 0.12
├── Chest          SpringBoneCollider radius 0.2, offset 0, 0.1, 0
└── Cape 1         SpringBones colliders Character
    └── Cape 2
        └── Cape End
```

The cape's `colliders` is Character, so it stays out of both spheres under it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `radius` | 0.1 | The sphere's radius, scaled by the object's largest scale. |
| `offset` | 0, 0, 0 | The sphere's center from the object, in the object's space. |

## Behavior

- It has no effect on its own. A SpringBones chain uses it when the chain's `colliders` is this object or an object above it.
- It is not a physics collider. Rigidbodies and raycasts do not see it.
- A chain's bone ends are pushed out of the sphere. The bone between two ends is not tested.
- Selected, it draws its sphere.
