---
title: "Image"
description: "A UI graphic that draws a sprite, or a solid colour, in its rect: simple, 9-sliced or tiled"
weight: 10
tags: ["mhgui", "components"]
---

A UI graphic that draws a sprite in its rect, or a solid colour when it has none. It needs a RectTransform and a CanvasRenderer on its node ([UI canvas](/plugins/engine/docs/UICanvas.md)).

## Example

```
Panel      RectTransform size_delta 400, 300, CanvasRenderer, Image sprite PanelFrame, image_type Sliced
Icon       RectTransform, CanvasRenderer, Image sprite Heart, preserve_aspect on
```

The panel stretches a 9-slice frame to its size without stretching the corners. The icon keeps its sprite's proportions inside its rect.

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | white | The tint, alpha included. |
| `material` | none | The material the quads draw with. |
| `raycast_target` | on | The pointer can hover and click this graphic. |
| `sprite` | none | A texture or one of its slices, picked in the Sprite row. None draws the plugin's white texture, so the rect is a solid `color`. |
| `image_type` | Simple | Simple, Sliced or Tiled, below. |
| `preserve_aspect` | off | Simple only: draws the largest rect with the sprite's aspect instead of stretching. |
| `fill_center` | on | Sliced and Tiled: draws the middle cell. |
| `pixels_per_unit_multiplier` | 1 | Sliced and Tiled: scales the size the borders and tiles draw at. 2 halves them. |

## Image types

- **Simple** stretches the sprite over the rect.
- **Sliced** keeps the sprite's 9-slice borders at their pixel size and stretches the edges and the center.
- **Tiled** keeps the corners and tiles the edges and the center, cutting the last tiles.
- Without borders, Sliced is a stretch and Tiled tiles the whole sprite.

The borders live on the sprite and are edited in the [Sprite Editor](/plugins/sprites/docs/windows/SpriteEditorWindow.md): for the selected slice, or the whole texture's in Single mode.

## In the editor

- Set Native Size sizes the RectTransform to the sprite's pixels, in one undo step.
- GameObject, UI, Image adds one under the selection when it sits in a canvas, else under a new canvas.
