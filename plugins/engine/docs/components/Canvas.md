---
title: "Canvas"
description: "The root of a UI tree: screen overlay, in front of a camera, or in the world"
weight: 100
tags: ["engine", "ui", "components"]
path: engine/components
---

The root of a UI tree ([UI canvas](../UICanvas.md)). GameObject, UI, Canvas adds one with a GraphicRaycaster.

## Example

```
Canvas             Canvas render_mode Screen Space Overlay, CanvasScaler, GraphicRaycaster
└── Panel          RectTransform, CanvasRenderer, Image
    └── Play       RectTransform, CanvasRenderer, Image, Button
```

A menu drawn over the game. The scaler keeps it the same size on every screen, and the raycaster lets the pointer reach the button.

## Properties

| Field | Default | What it does |
|---|---|---|
| `render_mode` | Screen Space Overlay | Overlay, Camera or World Space, below. |
| `render_camera` | none | Screen Space Camera: the camera it sits in front of. |
| `plane_distance` | 100 | Screen Space Camera: how far in front of the camera. |
| `sort_order` | 0 | Canvases stack by it. |

## Render modes

- **Screen Space Overlay.** The canvas rect is the game viewport in canvas units, drawn over everything. The node's transform is ignored.
- **Screen Space Camera.** The same rect placed `plane_distance` in front of `render_camera`, facing it and scaled so its height spans the camera's view there, drawn by that camera with depth, so world objects can hide it. Without a camera it behaves as Overlay.
- **World Space.** The node's RectTransform gives the size around its pivot and the node's transform places it, one canvas unit per world unit, drawn by every camera.

The Scene window shows all three where they sit in the world.
