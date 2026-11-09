---
title: "UI canvas"
description: "@(canvas_graphic) and @(canvas_layout): what a canvas component draws inside its rect, and containers that lay out their children"
weight: 60
tags: ["engine", "attributes", "ui"]
path: engine/attributes
---

Two attributes extend the [UI canvas](../UICanvas.md). The mhgui plugin's Image and LayoutGroup and the text plugin's Text use them.

## @(canvas_graphic)

```odin
@(canvas_graphic)
canvas_populate_Image :: proc(img: ^Image, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
    // append the quads that fill rect
}
```

- The proc is `canvas_populate_T`. T is a struct of the same package with a `graphic` field.
- It appends the quads the component draws inside its resolved rect. The canvas collector draws them.

## @(canvas_layout)

```odin
@(canvas_layout)
canvas_layout_groups :: proc(tH: engine.Transform_Handle, rect: engine.Rect,
    children: []engine.Transform_Handle, out: []engine.Rect) -> bool {
    // fill out with one rect per child, or return false
}
```

- The engine asks every layout provider for every canvas node, with the node's rect and its RectTransform children.
- A provider that lays the children out fills `out` and returns true. One that returns false leaves them to their anchors.

## Reference

- [@(canvas_graphic)](/docs/reference/attributes/engine/canvas_graphic.md), [@(canvas_layout)](/docs/reference/attributes/engine/canvas_layout.md)
- [UI canvas](../UICanvas.md), "Graphics".
