---
title: "UiMask"
description: "Clips the UI nodes under it to its rect, with round corners and a soft edge: what lies outside is not drawn and takes no pointer"
weight: 150
tags: ["engine", "ui", "components", "mask", "clipping"]
path: engine/components
---

Clips the nodes under it to its rect. What lies outside the rect is not drawn and takes no pointer.

## Example

```
Viewport       RectTransform size_delta 300, 200, CanvasRenderer, Image, UiMask
└── Content    RectTransform size_delta 300, 900
    ├── Row 1  RectTransform, CanvasRenderer, Image, Button
    └── ...
```

The rows show inside the viewport's 300 by 200 rect only. A row that is half out is cut at the edge, and its hidden half cannot be pressed. Moving Content up and down scrolls the rows.

## Properties

| Field | Default | What it does |
|---|---|---|
| `corner_radius` | 0 | The radius of the round corners, in canvas units. It is cut to half the shorter side, so a large one on a square makes a circle. |
| `corners` | all four | Which corners are round: top left, top right, bottom right, bottom left. |
| `softness` | 0 | The width the edge fades over, inward, in canvas units. 0 is a crisp edge. |

The rect it clips to is the node's own, from its RectTransform.

## Behavior

- The clip follows the node: turned or scaled, and on a canvas in the world or before a camera, the nodes under it are cut along its own edges.
- A crisp edge is one pixel soft, so a turned mask and a round corner have no stair steps.
- The node's own graphic is not clipped. It is the picture behind the content. Give it the mask's radius, a UiShape with the same `corner_radius`, and the content follows the card's corners.
- The pointer follows the outline: a round corner's cut-away part takes no pointer.
- Quads under a mask merge into draw calls as they do without one: the mask costs no draw call.
- Disabling the component stops the clipping.

## A mask in a mask

A node is cut by every mask above it.

- The nearest mask cuts with its round corners and its soft edge.
- The masks above it cut as plain rects, with square corners and a crisp edge, folded into one rect.
- One of those further masks that is turned against the first of them is left out of the drawing. The pointer still follows every mask.

## Shaders

The shader of a clipped quad does the clipping.

- The built-in unlit shader (a UI graphic with no material), the text plugin's shader and the mhgui UiShape's shader clip.
- Another shader clips by declaring `frag_normal` (location 2), `frag_tangent` (location 4) and `frag_uv2` (location 5) and multiplying its alpha by `ui_clip(frag_tangent, frag_normal, frag_uv2)`, the function in `moonhug/libs/gfx/shaders/world.frag.glsl`. A shader without it draws its quads whole under a mask.
- A clipped quad carries its clip where an unclipped one carries its normal, its tangent and its second texture coordinate, so a lit material on a quad under a mask shades wrong.

## Limits

- One radius for the round corners. A corner is round with that radius or square.
- A soft edge wider than the corner radius shows a faint crease running in from each round corner.
- Only the nearest mask cuts with its shape (above).
