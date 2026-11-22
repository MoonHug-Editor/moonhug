---
title: "Scrollbar"
description: "A track with a handle that shows a place between two ends and sets it when dragged"
weight: 35
tags: ["mhgui", "components", "scroll"]
---

A track with a handle. It shows a place between two ends and how much of what is there shows, and sets the place when the pointer drags the handle or presses the track. A [ScrollRect](ScrollRect.md) drives one per axis.

## Example

```
Scrollbar   RectTransform 12 wide, CanvasRenderer, UiShape, Scrollbar handle Handle
└── Handle  RectTransform, CanvasRenderer, UiShape
```

The Scrollbar's node is the track, and the handle slides along it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `handle` | none | The node that slides, a child of the Scrollbar's node. |
| `direction` | Bottom_To_Top | Where value 0 is: the left, the right, the bottom or the top. |
| `value` | 1 | The place between the ends, 0 to 1. |
| `size` | 0.2 | The handle's length as a share of the track. |
| `min_handle` | 20 | The shortest the handle gets, in canvas units. |

## Behavior

- The Scrollbar places the handle by its anchors along the track. The handle's size and position along the track are not its own to set. Across the track it fills the bar.
- A press on the handle holds it where it was grabbed and drags it.
- A press on the track brings the handle's middle there, and the drag goes on from it.
- The Scrollbar keeps the drag from its press: no list above it takes it.
- With a ScrollRect: the bar follows the content, and a move of the handle moves the content. `size` is the share of the content that shows.
- Bottom_To_Top is what a ScrollRect's up and down uses: value 1 is the top.

## From code

`mhgui.scrollbar_set(bar, value, size)` sets both and places the handle. A bar used on its own, with no ScrollRect, is read through `value`, and `changed` is set when the pointer moved it.
