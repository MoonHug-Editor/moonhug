---
title: "Convex decompositions"
description: "Sets of convex hulls a model lists in its import settings, computed by CoACD in the editor, so a Rigidbody can carry a concave mesh"
weight: 30
tags: ["physics3d", "assets"]
---

A set of convex hulls that together approximate a concave mesh, so a [Rigidbody](../components/Rigidbody.md) can carry it through a [MeshCollider](../components/MeshCollider.md). A model lists its sets in its import settings, and the plugin computes them in the editor with CoACD.

## Import settings

The Convex Decompositions section under a model's import settings adds, edits and removes sets, applied with the import settings' Apply. Each set has:

| Setting | Default | What it does |
|---|---|---|
| mesh | the whole model | The mesh to split: the whole model or one of its parts. |
| Max Hulls | 8 | The most hulls to split it into, 2 to 256. |
| Concavity | 0.05 | How far a hull may stray from the surface before it is cut, as a fraction of the mesh's size. |
| Remesh Resolution | 50 | The grid a mesh that is not closed is first rebuilt on, in cells along its longest side, 20 to 100. |

A set is a sub-asset of the model, like a part or a clip, with a random id, so editing or removing other sets never repoints a collider. The Project window lists it under the model as "Hulls 8, 0.050".

## Computing

- After Apply, the editor computes each set with CoACD in a separate process, as many at once as the Physics 3D settings' `decompositions_at_once`.
- The status bar shows a running set, its stage and the elapsed time, with a Cancel button, and lists the others on hover. The model's section shows each set's state, with Cancel or Compute.
- A closed mesh takes under a second. A mesh that is not closed, as most game meshes are, is first rebuilt as a closed surface on the Remesh Resolution grid, and that sets most of the time. The DamagedHelmet, 8 hulls: 105 s at 50, 90 s at 40, 62 s at 30, 33 s at 20, every resolution covering 99.4% or more of its vertices, the coarser grids giving hulls up to 16% larger by volume.
- A cancelled or failed set stays without hulls until its Compute.

## Where the hulls are kept

- In the library beside the model's artifact, for the game.
- In the model's `.meta`, key `hulls`, base64, a few KB per set, 23 KB for 44 hulls. The `.meta` is committed.
- Both record a hash of the mesh and the settings they came from. A fresh clone or a reimport restores every set whose hash matches from the `.meta`, and only sets whose mesh or values changed are computed again.

## In the game

A game only reads the saved hulls, which an export ships with the model, and only for the sets its scenes use. CoACD never runs in a game.
