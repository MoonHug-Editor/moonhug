---
title: "Render Layers"
description: "The names of the 32 render layers that objects, cameras, lights and probes pick"
weight: 60
tags: ["engine", "assets", "rendering"]
path: engine/assets
---

The names of the 32 render layers. Assets, Create, Render Layers makes one, and the Layers project setting picks the one the project uses.

| Field | What it does |
|---|---|
| `names` | The layer names. Layers 0 and 31 are built in. An empty name is an unused layer. |

An object's `render_layer`, a camera's `render_layer_mask`, a light's `culling_mask` and `shadow_caster_mask`, and a probe's `culling_mask` all pick from these names. A rename reaches every picker at once ([Layers](../Layers.md)).
