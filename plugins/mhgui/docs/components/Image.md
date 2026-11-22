---
title: "Image"
description: "A UI graphic that draws a sprite, or a solid colour, in its rect: simple, 9-sliced, tiled, or filled by an amount for bars and cooldowns"
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
| `image_type` | Simple | Simple, Sliced, Tiled or Filled, below. |
| `preserve_aspect` | off | Simple and Filled: draws the largest rect with the sprite's aspect instead of stretching. |
| `fill_center` | on | Sliced and Tiled: draws the middle cell. |
| `pixels_per_unit_multiplier` | 1 | Sliced and Tiled: scales the size the borders and tiles draw at. 2 halves them. |
| `fill_method` | Horizontal | Filled: Horizontal, Vertical, Radial_90, Radial_180 or Radial_360, below. |
| `fill_origin` | Bottom | Filled: where the fill starts, below. |
| `fill_amount` | 1 | Filled: how much of the image shows, 0 to 1. |
| `fill_clockwise` | on | Filled, radial: the sweep turns clockwise. |

## Image types

- **Simple** stretches the sprite over the rect.
- **Sliced** keeps the sprite's 9-slice borders at their pixel size and stretches the edges and the center.
- **Tiled** keeps the corners and tiles the edges and the center, cutting the last tiles.
- **Filled** draws `fill_amount` of the stretched sprite and nothing of the rest: a health bar, a progress bar, a cooldown over an icon.
- Without borders, Sliced is a stretch and Tiled tiles the whole sprite.

The borders live on the sprite and are edited in the [Sprite Editor](/plugins/sprites/docs/windows/SpriteEditorWindow.md): for the selected slice, or the whole texture's in Single mode.

## Filled

```
Health     RectTransform size_delta 200, 16, CanvasRenderer, Image image_type Filled, fill_method Horizontal, fill_origin Left
Cooldown   RectTransform size_delta 64, 64, CanvasRenderer, Image sprite Dim, image_type Filled, fill_method Radial_360, fill_origin Top
```

Game code sets `fill_amount` each frame: the bar shortens toward its left end, and the dim square over the ability's icon sweeps away like a clock hand.

| Method | What shows | `fill_origin` |
|---|---|---|
| Horizontal | A bar that grows across. | Left or Right: the side it grows from. Any other is Left. |
| Vertical | A bar that grows up or down. | Bottom or Top: the side it grows from. Any other is Bottom. |
| Radial_360 | A sector round the centre of the rect. | The edge the sweep starts at. |
| Radial_180 | A sector round the middle of an edge, half a turn at most. | The edge it turns on. |
| Radial_90 | A sector round a corner, a quarter turn at most. | The corner: Bottom is bottom left, Right bottom right, Top top right, Left top left. |

- The part that shows keeps its place in the sprite: the picture does not squeeze as the amount changes.
- A sector is cut by angle, so in a rect that is not square equal steps of `fill_amount` are equal angles, not equal areas.
- The 9-slice borders are not used.

## In the editor

- Set Native Size sizes the RectTransform to the sprite's pixels, in one undo step.
- GameObject, UI, Image adds one under the selection when it sits in a canvas, else under a new canvas.
