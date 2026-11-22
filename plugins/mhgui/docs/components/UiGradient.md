---
title: "UiGradient"
description: "An effect that runs a gradient across the graphic on its node: a Text, an Image or a UiPolygon"
weight: 40
tags: ["mhgui", "components", "effects", "gradient"]
---

An effect: it colours the graphic on its node from one colour to another. Add it beside an Image, a Text or a UiPolygon (Add Component, UI, Effects, UiGradient).

## Properties

| Field | Default | What it does |
|---|---|---|
| `direction` | Vertical | Vertical: `from` at the top, `to` at the bottom. Horizontal: `from` at the left, `to` at the right. |
| `span` | Content | What the gradient runs across, below. |
| `from` | white | The colour at the top or the left. |
| `to` | 0.6 grey | The colour at the bottom or the right. |

| Span | The gradient runs across |
|---|---|
| Content | Everything the graphic draws: the whole block of a Text, whatever the size of its rect. |
| Rect | The node's rect. |
| Each | Each quad by itself: every glyph of a Text from its own top to its own bottom. |

## Behavior

- Both colours multiply the graphic's own colour. On a white graphic they are the colours seen.
- The colour is set at the corners of each quad and runs smoothly between them, so a gradient across a Text changes from glyph to glyph and inside each glyph.
- A 9-sliced or tiled Image is coloured cell by cell, which gives the same picture as one gradient across it.
- A [UiShape](UiShape.md) has a gradient of its own with any angle. This effect works on it too, with two directions.
- Effects on one node run in the order of its components: a gradient before a [UiShadow](UiShadow.md) leaves the shadow its own colour.
