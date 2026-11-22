---
title: "LayoutGroup"
description: "Lays out its node's RectTransform children in a row, a column or a grid, with padding, spacing and alignment"
weight: 30
tags: ["mhgui", "components"]
---

Lays out its node's RectTransform children in a row, a column or a grid.

## Example

```
Inventory          RectTransform, LayoutGroup direction Grid, cell_size 80, 80, constraint Fixed_Column_Count, constraint_count 4
├── Slot           RectTransform, CanvasRenderer, Image
├── Slot           ...
└── Slot           ...
```

The slots fill a grid four columns wide, rows top to bottom. Adding a slot places it in the next cell.

## Properties

| Field | Default | What it does |
|---|---|---|
| `direction` | Horizontal | Horizontal runs left to right, Vertical top to bottom, Grid in cells, rows top to bottom and each row left to right. |
| `padding` | 0 | Space inside the rect's left, right, top and bottom edges. |
| `spacing` | 8, 8 | Space between items: x across, y down. |
| `child_alignment` | Upper_Left | Where the laid-out children sit in the padded rect, one of nine positions. |
| `cell_size` | 100, 100 | Grid: every cell's size. |
| `constraint` | Flexible | Grid: Flexible fits as many columns as the width allows, Fixed_Column_Count and Fixed_Row_Count use `constraint_count`. |
| `constraint_count` | 2 | Grid: the number of columns or rows. |
| `expand_width` | off | Row or column: the children fill the padded rect's width, below. |
| `expand_height` | off | Row or column: the children fill the padded rect's height. |

## Behavior

- A laid-out child's anchors and anchored position are ignored. Its place comes from the flow.
- In a grid every child is `cell_size`.
- Children without a RectTransform stay out of the layout, and so does a child whose [LayoutElement](LayoutElement.md) says `ignore_layout`.

## Sizes in a row and a column

Each child asks for a size, and the group gives it along the flow from the room it has.

- **What a child wants** is its `size_delta`. A [LayoutElement](LayoutElement.md) on it replaces that, and a [ContentSizeFitter](ContentSizeFitter.md) on it makes it its content's size.
- **Room left over** goes to the children whose LayoutElement has a `flexible` share, by their shares. With none flexible, `expand_width` in a row (`expand_height` in a column) shares it among all the children alike. With neither, the children keep their size and `child_alignment` places them.
- **Too little room** takes from every child the same part of what it can give, down to its LayoutElement's `min_size`. A child with no LayoutElement can give all of its size.
- **Across the flow** a child keeps the size it wants. `expand_height` in a row (`expand_width` in a column) makes each child as tall (as wide) as the padded rect.

## In the editor

A laid-out rect shows a dimmer outline and no handles in the Scene window, and its inspector greys the values the group drives.
