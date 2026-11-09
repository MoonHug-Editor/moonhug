---
title: "Sky"
description: "scene_sky: draws the Environment's sky behind the opaque meshes"
weight: 80
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_sky` draws the [Environment](../components/Environment.md)'s sky where the opaque meshes left the view empty, when the Environment's `draw_sky` is on. Reads and writes `hdr`.
