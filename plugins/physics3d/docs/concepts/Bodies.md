---
title: "Bodies"
description: "How components become box3d bodies and shapes, when they are built and synced, and how game code reads contacts and triggers"
weight: 10
tags: ["physics3d", "concepts"]
---

How the plugin turns components into box3d bodies. The code is `physics3d.odin`.

## How bodies form

- A collider with no [Rigidbody](../components/Rigidbody.md) on or above its object is a static body of its own.
- A collider on or below a Rigidbody attaches to that body as one of its shapes, so one body can have many. Its place relative to the body is baked when the body is built.
- A trigger collider is a sensor: it reports overlaps and does not collide.
- A collider's shape is scaled by its object's scale.

## The fixed step

- The physics step runs on the engine's fixed tick, at `@(fixed_update)` order 1000. In the editor it runs in play mode only.
- Each step builds the bodies and shapes that are new, moves each kinematic body to its transform, writes changed collision layers and materials into the live shapes, steps the box3d world, writes each dynamic body's position and rotation back to its transform, and collects the step's events.
- While a convex decomposition a collider uses is still being computed, the step holds the whole world still.

## Contact events

Contacts are polled, not called back. Each step buffers the contacts and sensor overlaps that began and ended in it. Read them from a `@(fixed_update)` proc with an order above 1000, so it runs after the step:

```odin
import "moonhug:packages/physics3d"

@(fixed_update={order = 1100})
react :: proc(dt: f32) {
	for c in physics3d.contact_begin_events() { /* c pairs the two transforms */ }
	for s in physics3d.sensor_begin_events() { /* the sensor first, the visitor second */ }
}
```

`contact_end_events` and `sensor_end_events` list the ends.

## Debug view

In a running game, F3 draws every enabled collider's wireframe. The editor draws the wireframes of selected colliders only, with the same geometry.

## See also

- [Collision layers](CollisionLayers.md)
