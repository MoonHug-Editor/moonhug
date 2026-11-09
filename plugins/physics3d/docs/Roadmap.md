---
title: "Roadmap"
description: "What the physics3d plugin does not do yet"
weight: 900
tags: ["physics3d", "roadmap"]
---

What the physics3d plugin does not do yet. How it works is in [Bodies](concepts/Bodies.md).

## Next

- **Joints** as components. Today they are box3d calls on `body_of` from game code.
- **Effectors**: areas that push or float bodies.
- **Faster convex decompositions.** A mesh that is not closed is slow: the DamagedHelmet takes about 2 minutes for 8 hulls and 5 for 44. Settings worth trying for speed, a decimation setting for the source mesh, and a list of decimations in the set, for an extra set of models with fewer polygons.

## Open

- CoACD reports stages, not a fraction, so the status bar shows the stage and the elapsed time instead of a progress bar.
- After a body is built, moving or scaling a child collider does not rebuild its shape.
- At runtime, edits of collider fields other than `layers` and the overrides do not reach the live shape. `body_of` gives the box3d body to change directly.
