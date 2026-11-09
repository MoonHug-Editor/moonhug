---
title: "Bodies"
description: "How components become box2d bodies and shapes, when they are built and synced, and how game code reads contacts and triggers"
weight: 10
tags: ["physics2d", "concepts"]
---

How the plugin turns components into box2d bodies. The code is `physics2d.odin`.

## How bodies form

- A collider with no [Rigidbody2D](../components/Rigidbody2D.md) on or above its object is a static body of its own.
- A collider on or below a Rigidbody2D attaches to that body as one of its shapes, so one body can have many. Its place relative to the body is baked when the body is built.
- A trigger collider is a sensor: it reports overlaps and does not collide.
- Bodies move in the XY plane and turn around Z. A collider's shape is scaled by its object's scale.

## The fixed step

- The physics step runs on the engine's fixed tick, at `@(fixed_update)` order 1000. In the editor it runs in play mode only.
- Each step builds the bodies and shapes that are new, moves each kinematic body to its transform, writes changed collision layers and materials into the live shapes, steps the box2d world, writes each dynamic body's position and rotation back to its transform, and collects the step's events.
- The world's gravity comes from the Physics 2D project settings, and an edit applies on the next step.

## Contact events

Contacts are polled, not called back. Each step buffers the contacts and sensor overlaps that began and ended in it. Read them from a `@(fixed_update)` proc with an order above 1000, so it runs after the step:

```odin
import "moonhug:packages/physics2d"

@(fixed_update={order = 1100})
react :: proc(dt: f32) {
	for c in physics2d.contact_begin_events() { /* c pairs the two transforms */ }
	for s in physics2d.sensor_begin_events() { /* the sensor first, the visitor second */ }
}
```

`contact_end_events` and `sensor_end_events` list the ends.

## Debug view

In a running game, F3 draws every enabled collider's outline. The editor draws the outlines of selected colliders only, with the same geometry.

## See also

- [Collision layers](CollisionLayers.md)
