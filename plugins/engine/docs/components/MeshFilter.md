---
title: "MeshFilter"
description: "Names the mesh its object draws: a whole model or one of its parts"
weight: 60
tags: ["engine", "rendering", "components"]
path: engine/components
---

Names the mesh its object draws. How it draws is the [MeshRenderer](MeshRenderer.md) beside it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `mesh` | none | A model, or one of its parts, picked in the Mesh row. The whole model is baked into one mesh with its nodes' transforms applied. A part is one glTF mesh in its own space, placed by this object's transform. |

## Behavior

- The reference is the model's guid and the part's id, so it survives a reimport that keeps the part ([Meshes](../Meshes.md)).
- Extracted scenes use parts, so animated node transforms move real geometry.
