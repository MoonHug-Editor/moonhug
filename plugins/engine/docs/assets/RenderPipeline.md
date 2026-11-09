---
title: "Render Pipeline"
description: "A .renderpipeline asset: the slots, the placed render steps in order, their port bindings and settings"
weight: 50
tags: ["engine", "assets", "rendering"]
path: engine/assets
---

A `.renderpipeline` file: which render steps run, in which order, with which settings. Assets, Create, Render Pipeline makes one, the Rendering project setting picks the one the project uses, and the essentials plugin ships `Default.renderpipeline`.

## The file

JSON with `slots`, the slot names, and `steps`, the placed steps in run order. A placed step has an id, the `step` it runs, its `slot` (`""` is the frame lane), `binds` for ports bound to another target name, `settings` for the values it changes from the step's defaults, and `muted`.

A new pipeline has one Main slot, the environment pass and the shadow atlas on the frame lane, and the shadow cascades, opaque, sky, under, transparent, over and final blit steps on Main.

## In the editor

- The Project Inspector shows its steps, and Open Render Pipeline opens the [Render Pipeline](../windows/RenderPipeline.md) window on it.
- Edits render as they are made, before the file is saved.

## See also

- [Render pipeline](../RenderPipeline.md), slots, lanes, ports and the default pipeline.
