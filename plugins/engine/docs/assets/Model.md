---
title: "Model"
description: "A glTF model: its meshes as parts, its animation clips, its convex decompositions, and Extract Assets"
weight: 20
tags: ["engine", "assets"]
path: engine/assets
---

A `.glb` or `.gltf` file. The importer bakes its meshes and lists them as parts a MeshFilter names. The animation plugin adds its clips, and the physics3d plugin its convex decompositions ([Meshes](../Meshes.md)).

## Import settings

Shown in the Project Inspector when the model is selected, and applied with Apply or dropped with Revert.

| Setting | Default | What it does |
|---|---|---|
| `scale` | 1 | A uniform scale applied at import. |
| `parts` | | One entry per glTF mesh, in file order, with a persistent id. Kept by the importer. |
| clips | | The model's animation clips, with an id and their own settings, shown under each clip ([Animation clip](/plugins/animation/docs/assets/AnimationClip.md)). |
| hull sets | | Convex decompositions, with the physics3d plugin ([Convex decompositions](/plugins/physics3d/docs/assets/ConvexDecompositions.md)). |

## Parts

- A [MeshFilter](../components/MeshFilter.md) names the whole model, baked into one mesh with its nodes' transforms applied, or one part, in its own space.
- An id is given at the first import and never reused, so a reference to a removed part stays broken instead of naming a newcomer.

## In the editor

- In the Project window a model expands to its parts, clips and hull sets.
- Dragging a model into the scene places it.
- Assets, Extract Assets turns the selected model into ordinary editable assets next to it: its embedded images as image files, one `.mat` per glTF material with its maps wired into the Lit block, one clip per glTF animation with the animation plugin, and a `.scene` of its node hierarchy that uses them all. A file that already exists is skipped, so running it again keeps your edits.
