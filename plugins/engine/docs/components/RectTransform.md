---
title: "RectTransform"
description: "A UI node's rect: anchors in its parent, size, pivot and position, in canvas units"
weight: 110
tags: ["engine", "ui", "components"]
path: engine/components
---

A UI node's rect, in canvas units with a bottom-left origin ([UI canvas](../UICanvas.md)).

## Example

```
Canvas             Canvas
├── Title          RectTransform anchor_min 0.5, 1, anchor_max 0.5, 1, anchored_position 0, -60, size_delta 600, 80
└── Bar            RectTransform anchor_min 0, 0, anchor_max 1, 0, size_delta 0, 40
```

The title stays centered 60 units below the top edge. The bar stretches across the bottom at any screen width, 40 units tall.

## Properties

| Field | Default | What it does |
|---|---|---|
| `anchor_min`, `anchor_max` | 0.5, 0.5 | The part of the parent rect the node is anchored to. |
| `size_delta` | 100, 100 | Added to the anchors' span. Equal anchors give a fixed size, spread anchors stretch, and `size_delta` is then the margin. |
| `pivot` | 0.5, 0.5 | The point the rect turns and scales around, 0 to 1 in each axis. |
| `anchored_position` | 0, 0, 0 | Where the pivot sits from the anchors' reference point. The third component is depth off the canvas plane. |

## Behavior

- The node's Transform rotation and scale apply around the pivot and compose down the hierarchy. A rotation around X or Y tilts the rect out of the canvas plane, while anchors and layout still resolve in the parent's unrotated space.
- `anchored_position` is the only stored position. `transform_set_local_position` and `transform_set_world_position` on the node convert into it ([UI canvas](../UICanvas.md), "Position").
- A node without a RectTransform passes its parent's rect through.

## In the editor

For a single UI node the inspector hides the Transform section and draws the RectTransform this way:

- The anchor preset button opens a 4 by 4 grid: left, center, right and stretch by top, middle, bottom and stretch. Shift also sets the pivot, Alt also moves the rect onto the anchors.
- Per axis the fields follow the anchors: Pos X and Width when the anchors coincide, Left and Right when they are apart, and the same for Y. Pos Z is the depth.
- Anchor and pivot edits keep the rect where it is. The [R] toggle is raw edit mode: only the values change, and the rect moves.
- Rotation and Scale are the Transform's rows.
- Every gesture is one undo step. With several objects selected an edit writes the value into each through its own anchors, pivot and parent, recording each object's prefab override.
- A rect a LayoutGroup lays out greys Pos X, Pos Y, Width and Height.
- The mhgui plugin's rect tool edits the rect in the Scene window ([Editing UI](/plugins/mhgui/docs/concepts/EditingUI.md)).
