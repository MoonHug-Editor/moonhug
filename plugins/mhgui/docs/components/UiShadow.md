---
title: "UiShadow"
description: "An effect that draws a copy of the graphic on its node behind it, moved and in its own colour: a drop shadow for a Text or an Image"
weight: 41
tags: ["mhgui", "components", "effects", "shadow"]
---

An effect: it draws a copy of the graphic on its node behind it, moved by `offset` and in its own colour. Add it beside a Text, an Image or a UiPolygon (Add Component, UI, Effects, UiShadow).

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | black at half alpha | The shadow's colour. Its alpha is multiplied by the graphic's, so a graphic that fades takes its shadow along. |
| `offset` | 1, -1 | How far the shadow is moved, in canvas units, y up. |

## Behavior

- The shadow has the graphic's exact outline and a hard edge. It is one more quad for each quad of the graphic: a Text of 20 glyphs draws 40.
- It draws in the same draw call as the graphic.
- Effects on one node run in the order of its components. A UiShadow after a [UiOutline](UiOutline.md) shadows the outline too. Two UiShadows make two shadows.
- A [UiShape](UiShape.md) has a soft shadow of its own, with blur and spread. Use that one on a UiShape.

## Limits

- No blur.
