---
title: "Queries"
description: "Asking the running 2D physics world what a ray hits, what a moving shape hits and what a shape touches: raycast, shape casts, overlaps, their layers and the object they ignore"
weight: 30
tags: ["physics2d", "raycast", "overlap", "shape cast"]
---

A query asks the 2D colliders of the running game a question without moving anything. The plugin has three: what a ray hits, what a moving shape hits, and what a shape touches.

```odin
import physics2d "moonhug:packages/physics2d"

feet := engine.transform_world_position(player).xy
if hit, ok := physics2d.raycast(feet, {0, -1}, 0.2, ignore = player); ok {
	// standing on hit.object, hit.point, hit.normal, hit.distance
}
```

## raycast

`raycast(origin, direction, max_distance, layers, ignore)` returns the first collider along the ray, in the XY plane the bodies live in, as a `Raycast_Hit`:

| Field | What it is |
|---|---|
| `object` | the object carrying the collider hit |
| `point` | where the ray meets its edge, in world space |
| `normal` | the edge's normal at `point` |
| `distance` | from `origin` to `point` |

- `direction` need not be of length 1.
- `layers` is a mask of [collision layers](CollisionLayers.md): a collider is hit when one of its layers is in it. All layers by default. The layer matrix plays no part: it says which colliders collide with each other, not what a query sees.
- `ignore` is an object the ray passes through, with every object under it. A character casting from its own position passes its own colliders this way.
- Triggers are passed through.
- It returns false when nothing is hit within `max_distance`.

## Query shapes

An overlap and a shape cast place a shape of their own in the world for the one call. It is no collider: nothing collides with it and it needs no object.

| Shape | Given as |
|---|---|
| circle | a center and a `radius` |
| box | a center, `half_extents` each way from it, and `angle` degrees counterclockwise |
| capsule | the segment from `a` to `b` and a `radius` |

```odin
// Everything within 3 units of the blast, the grenade left out.
for object in physics2d.overlap_circle(blast, 3, ignore = grenade) {
	// object is a Transform_Handle
}

// Whether a body half a unit thick can move 2 units to the right.
if hit, ok := physics2d.circle_cast(chest, 0.5, {1, 0}, 2, ignore = player); ok {
	// blocked after hit.distance by hit.object
}
```

## Overlaps

`overlap_circle(center, radius, ...)`, `overlap_box(center, half_extents, angle, ...)` and `overlap_capsule(a, b, radius, ...)` return every object with a collider the shape touches, as a list of `Transform_Handle`.

- `layers` and `ignore` are raycast's. Triggers are left out.
- An object with several colliders is listed once.
- The list is in no order.
- The list is allocated with the `allocator` argument, the temporary allocator by default, so it lasts until the frame ends. Pass another allocator to keep it, and delete it then.
- It is empty when nothing touches.

## Shape casts

`circle_cast(origin, radius, direction, max_distance, ...)`, `box_cast(origin, half_extents, direction, max_distance, angle, ...)` and `capsule_cast(a, b, radius, direction, max_distance, ...)` move the shape along `direction` and return the first collider it hits, as a `Raycast_Hit`. A shape cast finds what a ray slips past: a ledge beside the ray's line, a gap too narrow for the body.

- `distance` is how far the shape moves before it touches, and `point` where it touches.
- `layers`, `ignore` and triggers are raycast's.
- A collider the shape touches where it starts is hit at `distance` 0, with a zero `normal`: there is no surface it ran into. Pass the casting object as `ignore` to leave its own colliders out.
- The shape does not turn while it moves.

## When it works

- Only while the game runs. Bodies are built by the physics step, so in edit mode, and before the first step, a query hits nothing.
- A query sees the colliders where the last step left them. A body moved since by its transform is found at its old place until the next step.
- From the main thread, like the rest of the plugin.

For what this does not cover, such as every hit along a ray or a cast of another shape, `world()` gives the box2d world and `vendor:box2d` its query procs.
