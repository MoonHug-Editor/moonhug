---
title: "ContentSizeFitter"
description: "Sizes its node to its content: a Text to its string, a node with a LayoutGroup to its children"
weight: 33
tags: ["mhgui", "components", "layout"]
---

Sizes its node to its content, per axis.

## Example

```
Bubble      RectTransform, CanvasRenderer, UiShape, LayoutGroup direction Vertical padding 12, ContentSizeFitter Preferred_Size both ways
└── Text    RectTransform, CanvasRenderer, Text wrap off, ContentSizeFitter Preferred_Size both ways
```

The text is as large as its string. The bubble is as large as the text and its padding. Changing the string resizes both.

## Properties

| Field | Default | What it does |
|---|---|---|
| `horizontal_fit` | Unconstrained | How the width is set, below. |
| `vertical_fit` | Unconstrained | How the height is set. |

| Mode | The axis becomes |
|---|---|
| Unconstrained | the node's own size, from its RectTransform |
| Min_Size | the `min_size` of the node's [LayoutElement](LayoutElement.md) |
| Preferred_Size | what the content wants |

## What the content wants

- A node with a [LayoutGroup](LayoutGroup.md): what its children want, with the group's padding and spacing.
- A node with a Text: its string at its font size and its margins. With `wrap` on and the width not fitted, the height is what the node's width makes the text.
- A [LayoutElement](LayoutElement.md) with a `preferred_size` of 0 or more comes before both.
- A node with neither keeps its own size.

## Behavior

- The node grows and shrinks around its pivot. A pivot at the top keeps the top edge where it is, so a list that fits its rows grows downward.
- Under a LayoutGroup the group sizes the node, and it asks for the same sizes: a fitted Text in a row takes its string's width.
- It works in the editor as it does in the game: the rect follows as the content is edited.

## Another graphic

A graphic says what it wants with a `@(canvas_measure)` proc named `canvas_measure_<T>`, taking the component and the width to fit in ([UI canvas](/plugins/engine/docs/UICanvas.md), "Rects"). The text plugin's Text has one.
