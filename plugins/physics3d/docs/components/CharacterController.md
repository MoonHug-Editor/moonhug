---
title: "CharacterController"
description: "Moves an object by code without going through colliders: slides along walls, walks up slopes and steps, says when it stands on the ground"
weight: 15
tags: ["physics3d", "components"]
---

Moves an object by code without going through colliders. Game code says how far to go each frame, and the controller slides along walls, walks up gentle slopes and low steps, and says when it stands on the ground. For a player or an enemy that walks, where a [Rigidbody](Rigidbody.md) would tip over, bounce or slide.

## Example

```
Player     CharacterController center 0 1 0, radius 0.4, height 1.8
           PlayerMove (your script)
```

```odin
import physics3d "moonhug:packages/physics3d"

@(comp_update={component=PlayerMove})
comp_update_PlayerMove :: proc(dt: f32, p: ^PlayerMove) {
    _, cc := engine.transform_get_comp(p.owner, physics3d.CharacterController)
    if cc.is_grounded {
        p.fall = 0
        if jump_pressed() do p.fall = 5
    }
    p.fall -= 9.81 * dt
    walk := input_direction() * 4 // metres per second, across
    physics3d.character_move(cc, {walk.x * dt, p.fall * dt, walk.z * dt})
}
```

Gravity and jumping stay in the game's code: the controller only makes sure the move does not go through anything.

## Properties

| Field | Default | What it does |
|---|---|---|
| `center` | 0, 0, 0 | Where the capsule's middle is, from the object. With the object's position at the feet, half the height up. |
| `radius` | 0.5 | The capsule's radius, before the object's scale. |
| `height` | 2 | The capsule's height, round ends included. |
| `slope_limit` | 45 | The steepest ground it walks up, in degrees. Steeper ground is a wall, and it slides down it. |
| `step_offset` | 0.3 | The highest step it walks up onto. |
| `layers` | layer 0 | The collision layers it is on, and with the matrix, the layers it stops at ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers it also stops at, or never stops at, whatever the matrix says. |

## From code

`character_move(cc, motion)` moves the object by `motion`, in world units, and returns what it touched: `.Sides` (a wall, a too steep slope), `.Above` (a ceiling) and `.Below` (ground). After it, the component says:

| Field | What it says |
|---|---|
| `is_grounded` | It ended on ground it can stand on. |
| `ground_normal` | That ground's direction, up for flat ground. |
| `moved` | How far it went, which is less than `motion` when something was in the way. |
| `collision_flags` | What the move returned. |

Call it once a frame: the next move reads `is_grounded` to know whether it can step up and follow the ground down.

## Behavior

- The capsule stands upright whatever the object's rotation, so the object can turn to face where it walks.
- Across, it walks up ground no steeper than `slope_limit`, and ground steeper than that stops it like a wall.
- Stopped on the ground by something no higher than `step_offset`, it steps up onto it.
- Up or down, gentle ground stops it, so it stands still on a slope, and steep ground slides it down.
- Moving across or standing on the ground, it follows the ground down a step or a slope instead of hopping off.
- Triggers, and colliders on its own object or under it, never stop it.
- In the world it is a kinematic capsule: dynamic bodies it walks into are pushed, and rays hit it ([Queries](../concepts/Queries.md)). The fixed step moves it to the object.
- In the editor, while the game does not run, there is no physics world: a move goes where it is told.

## In the editor

A selected controller draws its capsule.

## Limits

- No push force of its own: what it pushes is pushed as by a kinematic body.
- It does not ride a moving platform by itself: add the platform's motion to the move.
