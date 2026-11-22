---
title: "AspectRatioFitter"
description: "Keeps its node at a width to height ratio: from its width, from its height, or fitted into or over its parent"
weight: 34
tags: ["mhgui", "components", "layout"]
---

Keeps its node at a width to height ratio.

## Example

```
Screen      RectTransform stretched over its parent
└── Video   RectTransform, CanvasRenderer, Image, AspectRatioFitter aspect_mode Fit_In_Parent, aspect_ratio 1.778
```

The video is the largest 16 to 9 rect that fits the screen, centred, with bars where the screen's shape differs.

## Properties

| Field | Default | What it does |
|---|---|---|
| `aspect_mode` | None | How the ratio is kept, below. |
| `aspect_ratio` | 1 | Width over height: 2 is twice as wide as tall. |

| Mode | The node's rect |
|---|---|
| None | its own |
| Width_Controls_Height | its own width, the height from the ratio |
| Height_Controls_Width | its own height, the width from the ratio |
| Fit_In_Parent | the largest rect of the ratio inside the parent, centred |
| Envelope_Parent | the smallest rect of the ratio that covers the parent, centred |

## Behavior

- The first two modes resize around the node's pivot.
- The last two take the parent's rect and ignore the node's own size and anchors.
- A node a LayoutGroup places is sized by the group: the fitter does nothing there.
