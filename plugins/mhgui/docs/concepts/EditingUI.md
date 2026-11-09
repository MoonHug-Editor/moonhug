---
title: "Editing UI"
description: "The GameObject UI menus, picking UI in the Scene window, and the rect tool that moves, resizes, re-anchors and re-pivots rects"
weight: 10
tags: ["mhgui", "concepts", "editor"]
---

How UI is edited in the editor. The code is `editor/mhgui_editor.odin` and `rect_drag.odin`.

## Menus

- GameObject, UI, Canvas creates a canvas at the scene root, with a GraphicRaycaster so the pointer reaches it.
- GameObject, UI, Image and GameObject, UI, Button create a node with a RectTransform, a CanvasRenderer and the graphic under the selection when it sits in a canvas, else under a new canvas.
- Each is one undo step.

## Picking

Clicking a UI rect in the Scene window selects it, and the rubber band selects every graphic whose rect it touches, in any canvas mode.

## The rect tool

The selected RectTransform shows the rect tool, built on the editor's handles ([Handles](/docs/core/Handles.md)):

- **Outline.** White with a dark line just inside, so it reads on light images too.
- **Corners and edges** resize, with the opposite edge fixed, and show a resize cursor. The body moves, with a move cursor.
- **Anchors**, outlined triangles with a one-pixel shadow, drag along the parent rect. Coinciding anchors overlap, and dragging one pulls it out. Shift also moves the pivot, Alt also moves the rect onto the anchors. While an anchor drags, dashed lines through the anchors span the parent rect, and the lowest horizontal and leftmost vertical line show the percentage each section takes.
- **Pivot**, a ring, drags inside the rect. Ctrl snaps it to the corners, edges and center.
- **Priority** under the pointer: the pivot, then corners and anchors, then edges, then the body. An anchor's hit area is its triangle, so coinciding anchors are told apart.
- Anchor and pivot drags keep the rect in place unless raw edit mode, [R] in the inspector, is on.
- One drag is one undo step.
- A rect a LayoutGroup lays out shows a dimmer outline and no handles.
