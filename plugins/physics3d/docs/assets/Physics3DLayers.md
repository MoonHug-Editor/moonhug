---
title: "Physics 3D Layers"
description: "The names of the 32 collision layers of the 3D colliders, and which pairs of layers collide"
weight: 20
tags: ["physics3d", "assets"]
---

The names of the 3D colliders' 32 collision layers, and which pairs of layers collide. Assets, Create, Physics 3D Layers makes one, and the Physics 3D project settings' `layers` picks the one the project uses. The plugin ships `Physics3DLayers.asset`.

## Fields

| Field | What it does |
|---|---|
| `names` | The 32 layer names. An empty name is an unused layer. |
| `rows` | Which pairs collide: bit j of row i set means a collider on layer i and one on layer j collide. |

A new asset, and a project with no asset picked, name layer 0 "Default" and let every pair collide.

## In the editor

- The inspector draws `rows` as a triangle of checkboxes labelled with the asset's own names ([Layers](/plugins/engine/docs/Layers.md), "Collision matrix inspector").
- An edit of the picked asset reaches the layer picker and the physics step at once, before it is saved, and so does a change of its file on disk or picking another asset.

## See also

- [Collision layers](../concepts/CollisionLayers.md), how the matrix and the overrides decide a pair.
