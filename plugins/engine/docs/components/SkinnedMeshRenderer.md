---
title: "SkinnedMeshRenderer"
description: "Draws a skinned mesh posed by a skeleton of transforms, skinned on the GPU"
weight: 80
tags: ["engine", "rendering", "components"]
path: engine/components
---

Draws a skinned mesh, posed by a skeleton of transforms. The mesh comes from a [MeshFilter](MeshFilter.md) on the same object.

## Properties

| Field | Default | What it does |
|---|---|---|
| `materials` | empty | One material per submesh, as on a MeshRenderer. |
| `root_bone` | none | Where the joint names are looked up. None searches the parent's subtree, where an extracted glTF puts the armature beside the mesh. |
| `cast_shadows`, `reflections` | On, Visible | As on a MeshRenderer. |

## Behavior

- A compute pass skins the vertices on the GPU each frame the pose changes. An idle pose costs one palette build and compare, not an upload and a dispatch.
- Culling and picking use the posed bounds, since a posed character has usually left its bind-pose box.
