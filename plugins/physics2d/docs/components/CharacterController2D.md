---
title: "CharacterController2D"
description: "Moves an object by code without going through 2D colliders: slides along walls, walks up slopes and steps, says when it stands on the ground"
weight: 15
tags: ["physics2d", "components"]
---

Moves an object by code without going through 2D colliders, in the XY plane. Game code says how far to go each frame, and the controller slides along walls, walks up gentle slopes and low steps, and says when it stands on the ground. For a platformer's player, where a [Rigidbody2D](Rigidbody2D.md) would tip over, bounce or slide. The 2D sibling of physics3d's CharacterController.

## Example

```odin
import physics2d "moonhug:packages/physics2d"

@(comp_update={component=PlayerMove})
comp_update_PlayerMove :: proc(dt: f32, p: ^PlayerMove) {
    _, cc := engine.transform_get_comp(p.owner, physics2d.CharacterController2D)
    if cc.is_grounded {
        p.fall = 0
        if jump_pressed() do p.fall = 8
    }
    p.fall -= 20 * dt
    physics2d.character_move(cc, {input_x() * 5 * dt, p.fall * dt})
}
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `offset` | 0, 0 | Where the capsule's middle is, from the object. With the object's position at the feet, half the height up. |
| `radius` | 0.5 | The capsule's radius, before the object's scale. |
| `height` | 2 | The capsule's height, round ends included. |
| `slope_limit` | 45 | The steepest ground it walks up, in degrees. Steeper ground is a wall, and it slides down it. |
| `step_offset` | 0.3 | The highest step it walks up onto. |
| `layers` | layer 0 | The collision layers it is on, and with the matrix, the layers it stops at ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers it also stops at, or never stops at, whatever the matrix says. |

## From code

`character_move(cc, motion)` moves the object by `motion` and returns what it touched: `.Sides`, `.Above` and `.Below`. After it, `is_grounded`, `ground_normal`, `moved` and `collision_flags` say what the move did. Call it once a frame.

## Behavior

The same as the 3D [CharacterController](/plugins/physics3d/docs/components/CharacterController.md): upright capsule, slopes up to `slope_limit`, steps up to `step_offset`, still on gentle slopes and sliding down steep ones, following the ground down, never stopped by triggers or its own object's colliders, a kinematic capsule in the world, and a plain move with no physics world.

## How it works

box2d's mover cast takes no filter callback, so the controller asks the world for one query category, `MOVER_QUERY_BIT`. Every solid 2D collider has that bit in its mask, and triggers and controllers' own capsules do not. No layer is that bit, so it changes no collision between shapes.

## In the editor

A selected controller draws its capsule.
