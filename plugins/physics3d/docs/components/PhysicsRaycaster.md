---
title: "PhysicsRaycaster"
description: "Lets the pointer reach 3D colliders: an object with a collider gets the pointer events a UI node gets"
weight: 10
tags: ["physics3d", "components", "pointer", "click"]
---

Lets the pointer reach 3D colliders. It goes on a Camera. An object with a collider under the pointer then gets pointer events as a UI node does: enter, exit, down, up, click, hold, drag and scroll.

## Example

```
Main Camera    Camera, PhysicsRaycaster
Door           BoxCollider, Door (a component with a @(comp_on_pointer) proc)
```

```odin
@(comp_on_pointer={component=Door})
comp_on_pointer_Door :: proc(d: ^Door, ev: ^pointer.Pointer_Event) {
	#partial switch ev.kind {
	case .Enter: d.highlighted = true
	case .Exit:  d.highlighted = false
	case .Click: d.open = !d.open
	}
}
```

The door lights up under the pointer and a click opens it. The same proc on a UI node would do the same.

## Properties

| Field | Default | What it does |
|---|---|---|
| `layers` | every layer | The physics layers whose colliders the pointer can hit. |
| `max_distance` | 1000 | How far from the camera the pointer reaches. |

## Behavior

- Each frame it casts a ray from its camera through the pointer and answers with the first collider hit. The rules of the events are [the pointer](/plugins/engine/docs/Pointer.md)'s, the same as for UI.
- The event goes to the object with the collider and then up its parents.
- `ev.source` is `World_3D`. `ev.world_position` and `ev.world_normal` are where the collider is hit.
- UI comes first: a pointer over a canvas's graphic hits nothing behind it. `pointer.over(.UI)` stays false over a collider.
- With several cameras that have one, the nearest hit wins.
- Triggers are passed through, as for every raycast.
- A finger on a touch screen works as the mouse does.

## Limits

- Colliders exist while the game runs, so nothing is hit in edit mode.
- The ray is cast over the whole game viewport. A camera that draws into a part of the screen is not taken into account.
- A collider in front of a canvas in the world does not hide the canvas from the pointer: UI is asked first.
