---
title: "CanvasRenderer"
description: "Marks a UI node as drawing its graphic"
weight: 120
tags: ["engine", "ui", "components"]
path: engine/components
---

Marks a UI node as drawing its graphic.

## Example

```
Icon       RectTransform, CanvasRenderer, Image sprite Heart
```

The Image says what to draw, and the CanvasRenderer draws it. GameObject, UI, Image adds both.

## Behavior

- What it draws is the node's graphic, such as an Image or a Text. It has no fields of its own.
- Disabling it hides the graphic.
- A Button's tint is a runtime colour on it, never saved.
