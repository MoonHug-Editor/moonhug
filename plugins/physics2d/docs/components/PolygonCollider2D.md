---
title: "PolygonCollider2D"
description: "Any simple polygon as a solid shape, concave included, starting from a sprite's outline"
weight: 50
tags: ["physics2d", "components"]
---

Any simple polygon as a solid shape: a closed path of points. A concave path collides as drawn.

## Properties

| Field | Default | What it does |
|---|---|---|
| `points` | see below | The closed path, around `offset`, before the object's scale. |
| `offset` | 0, 0 | Where the path's origin sits from the object. |
| `density` | 1 | How the body's mass spreads over its colliders, in kilograms per square metre. Decides the mass when the Rigidbody2D's `use_auto_mass` is on. |
| `material` | none | The [Physics Material 2D](../assets/PhysicsMaterial2D.md). None takes the Rigidbody2D's, then the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## Behavior

- **Starting shape.** Added in the editor to an object with a SpriteRenderer, the path starts as the outline of the sprite's opaque pixels, alpha above 127: the longest outline when the sprite has several parts, simplified to within 2 pixels, in the sprite's pixels per unit around its pivot. This needs the sprites plugin. Otherwise the path starts as five points on a circle. Reset takes the starting shape again.
- The path is split into convex pieces of at most 8 points, one box2d polygon each.
- A path that is not a simple polygon, with crossing edges or all its points on a line, builds nothing and says so in the log until it is edited.
- The object's scale applies per axis.

## In the editor

In the Handles tool, T, the points are dots to drag. Pressing on an edge inserts a point there and drags it, and Alt+click on a point deletes it, down to three points. Each is one undo step.
