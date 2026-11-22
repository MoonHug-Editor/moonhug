---
title: "UiPolygon"
description: "A UI graphic whose outline is a list of points, filled or drawn as a line: arrows, speech bubbles, chart areas and chart lines"
weight: 16
tags: ["mhgui", "components", "polygon", "mesh", "line"]
---

A UI graphic whose outline is a list of points. It draws as a mesh of triangles, filled, as a line through the points, or both. It needs a RectTransform and a CanvasRenderer on its node ([UI canvas](/plugins/engine/docs/UICanvas.md)). GameObject, UI, Polygon creates an arrow to start from.

A [UiShape](UiShape.md) draws rectangles, ellipses, polygons with equal sides and stars in a shader, with borders and soft shadows. A UiPolygon is for the outlines those do not cover.

## Example

```
Arrow      RectTransform size_delta 64, 50, CanvasRenderer, UiPolygon points (0, 0.3) (0.6, 0.3) (0.6, 0) (1, 0.5) (0.6, 1) (0.6, 0.7) (0, 0.7)
Chart      RectTransform size_delta 300, 120, CanvasRenderer, UiPolygon fill off, closed off, line_width 3, points (0, 0.2) (0.2, 0.55) (0.4, 0.35) ...
```

The arrow points right and stretches with its rect. The chart is a line through its values, left to right.

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | white | The fill, alpha included. |
| `material` | none | The material the mesh draws with. |
| `raycast_target` | on | The pointer can hover and click this graphic, on its fill and its line. |
| `points` | empty | The outline, in the node's rect: (0, 0) is the bottom left corner and (1, 1) the top right. |
| `fill` | on | Fill the outline. |
| `line_width` | 0 | The width of a line through the points, in canvas units. 0 draws none. |
| `line_color` | white | The line's colour. Its alpha is multiplied by the graphic's. |
| `closed` | on | The line goes back from the last point to the first. |
| `antialias` | on | Fade the edges over one canvas unit. |

## Behavior

- The points follow the rect: a wider rect is a wider shape. A line keeps its width.
- The outline may be concave, in either direction. It must not cross itself: one that does still draws, with parts filled wrong.
- The line draws over the fill, with sharp corners. A very sharp corner is cut short at three times the line's half width.
- With `antialias` the edges of the fill and of the line fade out over one canvas unit, by a strip of triangles whose outer points have no alpha. On a canvas scaled far up or down the fade is wider or thinner than a pixel.
- A [UiGradient](UiGradient.md) on the node runs a gradient across the shape, and [UiShadow](UiShadow.md) and [UiOutline](UiOutline.md) work on it as on any graphic.
- Fewer than three points fill nothing, and fewer than two draw nothing.
- The pointer hits the fill and the line, not the rest of the rect. A click beside an arrow's head goes to what is behind it.

## Editing the points

With the node selected and the Handles tool on (T), the Scene window shows the points:

- A dot on each point. Drag it to move the point. A point may go outside the rect.
- A smaller dot in the middle of each edge. Drag it to add a point there.
- A point is removed in the inspector's `points` list.

Each drag is one undo step.

## Limits

- The Scene window does not remove a point. The inspector's list does.
- No round corners or round line ends.
