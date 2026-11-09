---
title: "MeshRenderer"
description: "Draws its MeshFilter's mesh with one material per submesh, and says whether it casts shadows and shows in reflections"
weight: 70
tags: ["engine", "rendering", "components"]
path: engine/components
---

Draws the mesh its [MeshFilter](MeshFilter.md) names.

## Properties

| Field | Default | What it does |
|---|---|---|
| `materials` | empty | One material per submesh, in the mesh's order. A submesh without one draws with the default material ([Materials](../Materials.md)). |
| `cast_shadows` | On | On casts, each face culled as its material says. Off never casts. Double_Sided casts with no face culling, so a one-sided plane still shadows. |
| `reflections` | Visible | Hidden leaves it out of every reflection probe capture, so a mirror inside a probe's box does not reflect itself. |

## Behavior

- Meshes outside a camera's view are culled, and meshes with the same mesh and material draw instanced.
