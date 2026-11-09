---
title: "GraphicRaycaster"
description: "Lets the pointer reach the graphics of its canvas"
weight: 140
tags: ["engine", "ui", "components"]
path: engine/components
---

Lets the pointer reach the graphics of its canvas.

## Example

```
Canvas         Canvas, GraphicRaycaster
└── Play       RectTransform, CanvasRenderer, Image, Button
```

The pointer can press the button. Without the GraphicRaycaster on the Canvas node, the button draws but never reacts.

## Properties

| Field | Default | What it does |
|---|---|---|
| `ignore_reversed_graphics` | on | A graphic whose rect faces away from the viewer, flipped by a transform, is not hit. |

## Behavior

- It sits on the Canvas node, and the pointer looks for graphics only in canvases that have one ([UI canvas](../UICanvas.md), "The pointer").
- GameObject, UI, Canvas adds one.
