---
title: "physics2d"
description: "2D physics on box2d: Rigidbody2D, five collider shapes, physics materials, collision layers and polled contact events"
tags: ["physics2d", "plugin"]
---

The physics2d plugin simulates 2D physics with box2d. Add a Rigidbody2D and colliders to objects, press Play, and the plugin builds box2d bodies from them and steps them on the engine's fixed tick. The editor never simulates: bodies exist only while the game runs. Bodies move in the XY plane and turn around Z, and 1 world unit is 1 metre, 100 pixels of a sprite at the default pixels per unit.

## What it adds

**Components**

- [Rigidbody2D](components/Rigidbody2D.md) makes an object a simulated body.
- [BoxCollider2D](components/BoxCollider2D.md), [CircleCollider2D](components/CircleCollider2D.md) and [CapsuleCollider2D](components/CapsuleCollider2D.md): primitive shapes.
- [PolygonCollider2D](components/PolygonCollider2D.md): any simple polygon, concave included, taken from a sprite's outline when it has one.
- [EdgeCollider2D](components/EdgeCollider2D.md): an open line, for ground.

**Assets**

- [Physics Material 2D](assets/PhysicsMaterial2D.md): friction, bounciness and how they combine.
- [Physics 2D Layers](assets/Physics2DLayers.md): the layer names and which layers collide.

**Concepts**

- [Bodies](concepts/Bodies.md): how components become box2d bodies, the fixed step, and contact events.
- [Collision layers](concepts/CollisionLayers.md): which colliders collide, with the matrix and per-object overrides.

[Roadmap](Roadmap.md): joints, effectors and what does not re-sync yet.

## What it needs

- The engine plugin. box2d is Odin's `vendor:box2d` and needs no install.
- Optional, the sprites plugin. A PolygonCollider2D added to a sprite then starts as the outline of its opaque pixels. That part lives in the plugin's `sprites` subpackage ([Plugins](/docs/core/Plugins.md)).

## Project settings

Edit, Project Settings, Physics 2D. Saved in `ProjectSettings/physics_2d.json`, which the game reads too.

| Setting | Default | What it does |
|---|---|---|
| `gravity` | 0, -9.81 | The world's gravity, in metres per second squared. |
| `layers` | none | The [Physics 2D Layers](assets/Physics2DLayers.md) asset the colliders use. None is layer 0 "Default" with every pair colliding. |
| `default_material` | none | The [Physics Material 2D](assets/PhysicsMaterial2D.md) of every collider and body that names none. None is a new material's defaults. |

## Quick start

1. Add Component, Physics2D/BoxCollider2D on a wide, flat object: the ground.
2. On a sprite above it, add Physics2D/Rigidbody2D and Physics2D/CircleCollider2D.
3. Press Play: the sprite falls and lands on the ground.

## Extending

The plugin declares no attributes and has no registries.

- Game code reads contacts and triggers from `@(fixed_update)` procs ordered after the physics step ([Bodies](concepts/Bodies.md), "Contact events").
- `body_of(handle)` returns an object's live box2d body, and `world()` the box2d world, so forces, joints, raycasts and the rest of box2d work from game code.

## Limits

- No joints and no effectors as components ([Roadmap](Roadmap.md)).
- After a body is built, moving or scaling a child collider does not rebuild its shape, and runtime edits of collider fields other than the layers do not reach the live shape.

## Reference

- [API reference](/docs/reference/packages/physics2d/physics2d.md) of the `physics2d` package.
- Sample: `physics2d_sample`, `physics2d_sample.scene`: bodies falling onto a ground and a ramp. In the running game, F3 shows every collider's outline.
