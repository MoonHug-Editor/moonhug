---
title: "MeshCollider"
description: "A mesh's own shape: its convex hull, a convex decomposition into several hulls, or its triangles on a static body"
weight: 50
tags: ["physics3d", "components"]
---

A mesh's own shape, in one of three forms: its convex hull, a [convex decomposition](../assets/ConvexDecompositions.md) into several hulls, or its triangles as they are.

## Example

```
Level      MeshRenderer, MeshCollider mesh Level.glb, convex off
Barrel     Rigidbody, MeshCollider mesh Barrel.glb, convex on, hulls Convex Hull
```

The level collides as drawn and never moves. The barrel is a dynamic body, so it uses its mesh's convex hull.

## Properties

| Field | Default | What it does |
|---|---|---|
| `mesh` | none | A model or one of its parts. Empty uses the MeshFilter's mesh on the same object. |
| `convex` | off | Collide as convex. Off, the triangles collide as they are, on a static body only. |
| `hulls` | Convex Hull | With `convex` on: the single convex hull, or one of the convex decompositions of the collider's mesh. |
| `density` | 1 | How the body's mass spreads over its colliders: the center of mass and the inertia, in kilograms per cubic metre. |
| `material` | none | The [Physics Material](../assets/PhysicsMaterial.md). None takes the project's default. A foldout edits the asset in place. |
| `is_trigger` | off | A sensor: reports overlaps and lets bodies pass through. |
| `layers` | layer 0 | The collision layers this collider is on. Several are allowed ([Collision layers](../concepts/CollisionLayers.md)). |
| `include`, `exclude` | none | Layers this collider also collides with, or never collides with, whatever the matrix says. Drawn inline, from `layer_overrides`. |

## Behavior

- **Convex Hull.** The convex hull of the mesh's vertices, reduced to the 44 points a box3d hull holds. The only form a Rigidbody can carry besides a decomposition.
- **A decomposition.** One hull shape per hull of the picked set, so a Rigidbody carries a concave mesh. The collider stores the set as `{model guid, set id}`, so an export ships the hulls of the sets its scenes use and no others.
- **Triangles.** With `convex` off the mesh collides as drawn, on a static body only. Under a Rigidbody it builds nothing and says so in the log. A mesh of more than 128 triangles is split into chunks of at most 128, one child of a compound shape each, because box3d keeps at most 256 triangles per contact and drops the rest without a word, which lets bodies fall through a dense mesh.
- The object's scale applies per axis, mirrored scale included.
- While a set the collider uses is still being computed, physics holds the whole world still and says so in the Console, so no body falls without its collider.

## In the editor

- The Hulls dropdown lists Convex Hull and the sets of the collider's mesh. Under it, a set that is not ready shows its state.
- A selected collider draws the hull's edges when convex, and the mesh's triangles otherwise.
