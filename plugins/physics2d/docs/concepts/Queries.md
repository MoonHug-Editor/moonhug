---
title: "Queries"
description: "Asking the running 2D physics world what a ray hits: raycast, its layers, the object it ignores and what it passes through"
weight: 30
tags: ["physics2d", "raycast"]
---

A query asks the 2D colliders of the running game a question without moving anything. The plugin has one: what a ray hits.

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

## When it works

- Only while the game runs. Bodies are built by the physics step, so in edit mode, and before the first step, a query hits nothing.
- A query sees the colliders where the last step left them. A body moved since by its transform is found at its old place until the next step.
- From the main thread, like the rest of the plugin.

For what this does not cover, such as a shape cast or every hit along the ray, `world()` gives the box2d world and `vendor:box2d` its query procs.
