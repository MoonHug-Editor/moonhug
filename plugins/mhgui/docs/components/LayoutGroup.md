---
title: "LayoutGroup"
description: "Lays out its node's RectTransform children in a row, a column or a grid, with padding, spacing and alignment"
weight: 30
tags: ["mhgui", "components"]
---

Lays out its node's RectTransform children in a row, a column or a grid.

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

## Behavior

- A laid-out child's anchors and anchored position are ignored. Its size is its `size_delta`, or `cell_size` in a grid, and its place comes from the flow.
- Children without a RectTransform stay out of the layout.

## In the editor

A laid-out rect shows a dimmer outline and no handles in the Scene window, and its inspector greys the values the group drives.
