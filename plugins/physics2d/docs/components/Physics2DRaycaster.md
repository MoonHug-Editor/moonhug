---
title: "Physics2DRaycaster"
description: "Lets the pointer reach 2D colliders: an object with a collider gets the pointer events a UI node gets"
weight: 10
tags: ["physics2d", "components", "pointer", "click"]
---

Lets the pointer reach 2D colliders. It goes on a Camera. An object with a 2D collider under the pointer then gets pointer events as a UI node does: enter, exit, down, up, click, hold, drag and scroll.

## Example

```
Main Camera    Camera, Physics2DRaycaster
Coin           CircleCollider2D, Coin (a component with a @(comp_on_pointer) proc)
```

A click on the coin sends `Click` to the Coin component's proc, the same proc a UI node would use.

## Properties

| Field | Default | What it does |
|---|---|---|
| `layers` | every layer | The physics2d layers whose colliders the pointer can hit. |

## Behavior

- Each frame it finds where its camera's ray through the pointer crosses the XY plane, where the 2D bodies live, and answers with a collider that holds that point. The rules of the events are [the pointer](/plugins/engine/docs/Pointer.md)'s, the same as for UI.
- The event goes to the object with the collider and then up its parents.
- `ev.source` is `World_2D`. `ev.world_position` is the point on the plane.
- UI comes first: a pointer over a canvas's graphic hits nothing behind it.
- Triggers are passed through, as for every query.

## Limits

- Where colliders overlap, which one answers is not defined: there is no sorting by sprite order.
- Colliders exist while the game runs, so nothing is hit in edit mode.
