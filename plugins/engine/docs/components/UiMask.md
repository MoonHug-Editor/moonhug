---
title: "UiMask"
description: "Clips the UI nodes under it to its rect: what lies outside is not drawn and takes no pointer"
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

It has none. The rect it clips to is the node's own, from its RectTransform.

## Behavior

- The clip follows the node: turned or scaled, and on a canvas in the world or before a camera, the nodes under it are cut along its own edges.
- The edge is one pixel soft, so a turned mask has no stair steps.
- The node's own graphic is not clipped. It is the picture behind the content.
- A node is drawn clipped by the nearest UiMask above it. A mask inside a mask cuts its nodes to its own rect, so keep it inside the outer one. The pointer is stricter: a node takes no pointer where any mask above it cuts it.
- Quads under a mask merge into draw calls as they do without one: the mask costs no draw call.
- Disabling the component stops the clipping.

## Shaders

The shader of a clipped quad does the clipping.

- The built-in unlit shader (a UI graphic with no material), the text plugin's shader and the mhgui UiShape's shader clip.
- Another shader clips by declaring `layout(location = 4) in vec4 frag_tangent;` and multiplying its alpha by `ui_clip(frag_tangent)`, the function in `moonhug/libs/gfx/shaders/world.frag.glsl`. A shader without it draws its quads whole under a mask.
- A clipped quad carries its place in the mask's rect where an unclipped one carries its tangent, so a clipped quad has no tangent for a normal map.

## Limits

- The clip is a rectangle with square corners and a hard edge.
- Draw clipping takes the nearest mask only.
