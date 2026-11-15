---
title: "Physics primitives"
description: "GameObject, 3D Object, Cube, Sphere and Capsule (Physics): a primitive mesh with a Rigidbody and a matching collider"
weight: 10
tags: ["physics3d", "essentials", "concepts"]
---

Three menu items create a primitive that already falls and collides. The code is the plugin's `essentials/editor` subpackage, which builds only with the essentials plugin installed, since the meshes and the material are the essentials plugin's.

## The items

| Item | Mesh | Collider |
|---|---|---|
| GameObject, 3D Object, Cube (Physics) | the essentials cube, 1 x 1 x 1 | [BoxCollider](../../../../components/BoxCollider.md) |
| GameObject, 3D Object, Sphere (Physics) | the essentials sphere, radius 0.5 | [SphereCollider](../../../../components/SphereCollider.md) |
| GameObject, 3D Object, Capsule (Physics) | the essentials capsule, radius 0.5, height 2 | [CapsuleCollider](../../../../components/CapsuleCollider.md) |

## What each creates

- An object with a MeshFilter, a MeshRenderer with the essentials Default material, a [Rigidbody](../../../../components/Rigidbody.md) and the collider.
- The collider's defaults match the mesh exactly, so nothing needs sizing.
- The whole object is one undo step.

## See also

- [API reference](/docs/reference/packages/physics3d/essentials_editor.md) of the `essentials_editor` package, the three menu items with links to the code.
