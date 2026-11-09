---
title: "physics3d"
description: "3D physics on box3d: Rigidbody, box, sphere, capsule and mesh colliders, convex decompositions, physics materials, collision layers and polled contact events"
tags: ["physics3d", "plugin"]
---

The physics3d plugin simulates 3D physics with box3d. Add a Rigidbody and colliders to objects, press Play, and the plugin builds box3d bodies from them and steps them on the engine's fixed tick. The editor never simulates: bodies exist only while the game runs. 1 world unit is 1 metre.

## What it adds

**Components**

- [Rigidbody](components/Rigidbody.md) makes an object a dynamic or kinematic body.
- [BoxCollider](components/BoxCollider.md), [SphereCollider](components/SphereCollider.md) and [CapsuleCollider](components/CapsuleCollider.md): primitive shapes.
- [MeshCollider](components/MeshCollider.md): a mesh's own shape, as one convex hull, a convex decomposition, or its triangles.

**Assets**

- [Physics Material](assets/PhysicsMaterial.md): friction, bounciness and how they combine.
- [Physics 3D Layers](assets/Physics3DLayers.md): the layer names and which layers collide.
- [Convex decompositions](assets/ConvexDecompositions.md): sets of convex hulls a model lists in its import settings, computed by CoACD.

**Concepts**

- [Bodies](concepts/Bodies.md): how components become box3d bodies, the fixed step, and contact events.
- [Collision layers](concepts/CollisionLayers.md): which colliders collide, with the matrix and per-object overrides.

[Roadmap](Roadmap.md): joints, effectors, faster decompositions and what does not re-sync yet.

## What it needs

- The engine plugin. box3d is `vendor:box3d` and needs no install. The CoACD tool that computes convex decompositions ships in the plugin's `external/CoACD` and runs in the editor only.
- Optional, the essentials plugin. It adds GameObject, 3D Object, Cube, Sphere and Capsule (Physics): a primitive mesh with a Rigidbody and a matching collider, in one undo step. That part lives in the plugin's `essentials` subpackage ([Plugins](/docs/core/Plugins.md)).

## Project settings

Edit, Project Settings, Physics 3D. Saved in `ProjectSettings/physics_3d.json`, which the game reads too.

| Setting | Default | What it does |
|---|---|---|
| `layers` | none | The [Physics 3D Layers](assets/Physics3DLayers.md) asset the colliders use. None is layer 0 "Default" with every pair colliding. |
| `default_material` | none | The [Physics Material](assets/PhysicsMaterial.md) of every collider that names none. None is a new material's defaults. |
| `decompositions_at_once` | 2 | How many convex decompositions the editor computes at the same time, 1 to 4, each in its own process. A dense mesh that is not closed takes about 2 GB of memory, so more than 2 or 3 mostly slows them all down. The game never reads it. |

Gravity is 0, -9.81, 0 by default, and `set_gravity` changes it from code.

## Quick start

1. GameObject, 3D Object, Cube (Physics), with the essentials plugin installed. Or add Physics/Rigidbody and Physics/BoxCollider to any object.
2. Give a wide, flat object a BoxCollider and no Rigidbody: the ground.
3. Press Play: the cube falls and lands.

## Extending

The plugin declares no attributes and has no registries.

- Game code reads contacts and triggers from `@(fixed_update)` procs ordered after the physics step ([Bodies](concepts/Bodies.md), "Contact events").
- `body_of(handle)` returns an object's live box3d body, and `world()` the box3d world, so forces, joints, raycasts and the rest of box3d work from game code.

## Limits

- No joints and no effectors as components ([Roadmap](Roadmap.md)).
- A non-convex MeshCollider works on a static body only.
- After a body is built, moving or scaling a child collider does not rebuild its shape, and runtime edits of collider fields other than the layers do not reach the live shape.

## Reference

- [API reference](/docs/reference/packages/physics3d/physics3d.md) of the `physics3d` package.
- Sample: `physics3d_sample`, `physics3d_sample.scene`: bodies falling onto a ground and a ramp. In the running game, F3 shows every collider's wireframe.
