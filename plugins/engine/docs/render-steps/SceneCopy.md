---
title: "Scene copy"
description: "scene_copy: copies the opaque image for refracting materials and next frame's reflections"
weight: 90
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_copy` copies the opaque image into `scene_color`, for the materials that refract and for next frame's screen-space reflections. Reads `hdr`.

- It goes before `scene_under`, so the editor's grid is neither refracted nor mirrored.
