---
title: "LayoutElement"
description: "What a node asks of the LayoutGroup that places it: its least size, the size it wants, its share of spare room, or to be left out"
weight: 32
tags: ["mhgui", "components", "layout"]
---

What a node asks of the [LayoutGroup](LayoutGroup.md) that places it. Without one, a node asks for its own size and nothing more.

## Example

```
Toolbar     RectTransform 400 x 44, LayoutGroup direction Horizontal, expand_height on
├── Back    RectTransform 44 wide
├── Title   RectTransform, LayoutElement flexible 1, 0
└── Menu    RectTransform 44 wide
```

Back and Menu keep their 44 units. Title takes all the room between them, whatever the toolbar's width.

## Properties

| Field | Default | What it does |
|---|---|---|
| `ignore_layout` | off | The layout leaves the node out: it keeps the rect its own anchors give it. |
| `min_size` | 0, 0 | The least the node takes when the layout has too little room. |
| `preferred_size` | -1, -1 | What the node wants. Under 0 leaves an axis to the node's content or its own size. |
| `flexible` | 0, 0 | The node's share of the room the layout has left over along its flow. 0 takes none. |

## Behavior

- Two children with `flexible` 1 and 3 get a quarter and three quarters of the spare room.
- `min_size` also feeds a [ContentSizeFitter](ContentSizeFitter.md) on the same node set to Min_Size, and `preferred_size` one set to Preferred_Size.
- Outside a row or a column it does nothing: a grid gives every child its cell.
