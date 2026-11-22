---
title: "ScrollRect"
description: "Scrolls a content node inside a viewport: by a drag, the wheel or a scrollbar, with inertia and elastic or clamped ends"
weight: 30
tags: ["mhgui", "components", "scroll", "list"]
---

Scrolls a content node inside a viewport. GameObject, UI, Scroll View creates a ready one.

## Example

```
Scroll View     RectTransform 300 x 200, CanvasRenderer, UiShape, ScrollRect content Content, viewport Viewport, vertical_scrollbar Scrollbar
├── Viewport    RectTransform stretched, UiMask
│   └── Content RectTransform 400 tall, hanging from the top
│       ├── Row 1   RectTransform, CanvasRenderer, UiShape, Button
│       └── ...
└── Scrollbar   RectTransform at the right edge, CanvasRenderer, UiShape, Scrollbar handle Handle
    └── Handle  RectTransform, CanvasRenderer, UiShape
```

The rows show inside the viewport, cut by its mask. A drag anywhere on the view scrolls them, a row's Button under the pointer included: the Button does not click. The wheel scrolls, and so does the bar.

The sample scene `ui_demo.scene` of the `mhgui_sample` package has one. Press Play to use it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `content` | none | The node that moves. A node under the viewport with a RectTransform. |
| `viewport` | none | The node the content shows in. None is the ScrollRect's own node. |
| `horizontal` | off | The content scrolls across. |
| `vertical` | on | The content scrolls up and down. |
| `movement` | Elastic | What happens at the ends, below. |
| `elasticity` | 0.1 | Elastic: seconds the content takes to come back from past an end. |
| `inertia` | on | After a drag the content keeps moving and slows down. |
| `deceleration_rate` | 0.135 | The share of its speed the content keeps each second. 0 stops at once. |
| `scroll_sensitivity` | 40 | Canvas units one notch of the wheel scrolls. |
| `horizontal_scrollbar`, `vertical_scrollbar` | none | The nodes with the [Scrollbar](Scrollbar.md) of each axis. |

## Movement

- **Elastic.** The content can be pulled past an end, less and less the further it goes, and comes back when let go.
- **Clamped.** The content stops at the ends.
- **Unrestricted.** There are no ends.

Content smaller than the viewport does not scroll: it sits at the viewport's left and top.

## The pointer

The ScrollRect takes the [pointer events](../concepts/Pointer.md) of its node, as every component does. The pointer has to hit something on the node or under it: a row, the panel's graphic, or a HitArea.

- **A drag** along an axis it scrolls is its own. What was pressed, a Button in a row, gets Cancel and does not click.
- **A drag along an axis it does not scroll** is left alone and reaches what is above. A list that scrolls across inside one that scrolls up and down works this way: each takes the drags along its own axis.
- **The wheel** scrolls it. At an end the wheel is left alone and scrolls the ScrollRect around it.
- A list that scrolls across only takes the wheel too, unless a ScrollRect above it scrolls up and down: then the wheel is that one's.
- **A press** on the view stops the content where it is. A press on a control that uses it, a Button, does not reach the ScrollRect: the content stops when the drag begins.
- The content scrolls in real time, so a menu scrolls while the game's time is held.

## From code

```odin
_, scroll := engine.transform_get_comp(list, mhgui.ScrollRect)
at := mhgui.scroll_rect_normalized(scroll)      // x 0 = its left shows, y 1 = its top shows
mhgui.scroll_rect_set_normalized(scroll, {0, 1}) // to the top
mhgui.scroll_rect_show(scroll, row)              // the least scroll that brings `row` into view
```

`scroll_rect_show` is what a list does when the keyboard or the gamepad moves the selection to a row out of view.

## Limits

- The rows all exist: a list of thousands of rows is thousands of nodes. Reusing a few rows for a long list is not built in.
- No snapping to a row or a page.
- The scrollbars do not hide when there is nothing to scroll.
