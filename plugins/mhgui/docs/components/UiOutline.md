---
title: "UiOutline"
description: "An effect that draws an outline round the graphic on its node, in its own colour: readable text over any background"
weight: 42
tags: ["mhgui", "components", "effects", "outline"]
---

An effect: it draws an outline round the graphic on its node. Add it beside a Text, an Image or a UiPolygon (Add Component, UI, Effects, UiOutline).

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | black | The outline's colour. Its alpha is multiplied by the graphic's. |
| `width` | 1 | How far the outline reaches, in canvas units. |

## Behavior

- The outline is eight copies of the graphic behind it, moved by `width` in eight directions. A Text of 20 glyphs draws 180 quads.
- It draws in the same draw call as the graphic.
- It holds for a width up to about the thickness of the graphic's thinnest stroke. Wider, the eight copies show apart at sharp corners.
- Effects on one node run in the order of its components: a [UiShadow](UiShadow.md) after it shadows the outline too.

## Limits

- A [UiShape](UiShape.md) has a border of its own, drawn in its shader. Use that one on a UiShape.
