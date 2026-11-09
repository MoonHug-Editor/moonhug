---
title: "Roadmap"
description: "What the physics2d plugin does not do yet"
weight: 900
tags: ["physics2d", "roadmap"]
---

What the physics2d plugin does not do yet. How it works is in [Bodies](concepts/Bodies.md).

## Next

- **Joints** as components. Today they are box2d calls on `body_of` from game code.
- **Effectors**: areas that push, float or one-way platforms.

## Open

- After a body is built, moving or scaling a child collider does not rebuild its shape.
- At runtime, edits of collider fields other than `layers` and `layer_overrides` do not reach the live shape. `body_of` gives the box2d body to change directly.
