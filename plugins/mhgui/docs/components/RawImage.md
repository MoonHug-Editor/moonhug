---
title: "RawImage"
description: "A UI graphic that draws a texture, whole or a part of it given in uv: a backdrop that scrolls or repeats"
weight: 11
tags: ["mhgui", "components", "texture", "uv"]
---

A UI graphic that draws a texture stretched over its rect, whole or the part `uv_rect` names. It needs a RectTransform and a CanvasRenderer on its node ([UI canvas](/plugins/engine/docs/UICanvas.md)).

An [Image](Image.md) draws a sprite: a slice with borders, 9-sliced, tiled or filled. A RawImage draws the texture itself and says which part of it in uv.

## Example

```
Clouds     RectTransform stretched, CanvasRenderer, RawImage texture Clouds, uv_rect 0, 0, 3, 1
```

The texture's wrap is Repeat, so the clouds show three times across. Game code adds to `uv_rect.x` each frame and they drift.

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | white | The tint, alpha included. |
| `material` | none | The material the quad draws with. |
| `raycast_target` | on | The pointer can hover and click this graphic. |
| `texture` | none | The texture to draw. None draws a solid `color`. |
| `uv_rect` | 0, 0, 1, 1 | The part of the texture that shows: x, y, width and height, y up. 0, 0, 1, 1 is the whole of it. |

## Behavior

- The part that shows stretches over the rect, whatever its aspect.
- A `uv_rect` past the texture's edge shows what the texture's wrap gives there: more copies with Repeat, the edge's pixels with Clamp.
- A negative width or height flips the picture.
- The texture's sprite slices and borders are not used.
- A [ContentSizeFitter](ContentSizeFitter.md) sizes the node to the part's size in pixels.

## Limits

- The texture is a texture file. The engine has no render target asset, so a camera's picture cannot be shown this way yet.
