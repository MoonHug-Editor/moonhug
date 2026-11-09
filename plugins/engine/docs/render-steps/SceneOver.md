---
title: "Scene over"
description: "scene_over: what the host draws over the finished image, gizmos and debug draw"
weight: 140
tags: ["engine", "rendering", "render-steps"]
path: engine/render-steps
---

`scene_over` draws what the host puts over the finished image: the editor's gizmos and the game's debug draw. Reads `final` and `hdr`, writes `hdr`.

- It comes after the post steps, so exposure, bloom and tonemapping leave the gizmos' colours alone. It depth-tests them against the scene's depth.
- A pipeline that puts it earlier gets post effects on the gizmos too.
