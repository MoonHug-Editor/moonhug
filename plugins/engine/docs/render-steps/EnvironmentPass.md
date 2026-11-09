---
title: "Environment"
description: "environment_pass: renders the scene's Environment into cubes for reflections and ambient light when it changes"
weight: 10
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`environment_pass`, a frame step. Renders the scene's [Environment](../components/Environment.md) into cubes for reflections and ambient light, when it changed. Reads `scene`.

- The sky goes into a source cube, a GGX prefilter fills the reflection cube along its mips, and an irradiance pass fills the diffuse light ([Materials](../Materials.md), "Environment").
- Nothing runs while the Environment is unchanged.
