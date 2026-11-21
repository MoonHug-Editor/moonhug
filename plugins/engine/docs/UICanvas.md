---
title: "UI canvas"
description: "The canvas tree in the engine: Canvas, RectTransform, CanvasRenderer, CanvasScaler and GraphicRaycaster, rect layout, positions, drawing and the pointer"
weight: 60
tags: ["ui", "rendering", "components"]
path: engine/concepts/rendering
---

UI has two halves. The canvas tree is engine vocabulary, in `plugins/engine/ui_canvas.odin`: the components that lay out rects and the walk that resolves every node's rect. What gets drawn is content in plugins: the [mhgui](/plugins/mhgui/docs/_index.md) plugin's Image, Button and LayoutGroup, and the [text](/plugins/text/docs/_index.md) plugin's Text. Any plugin builds on the tree through `canvas_resolve_rects`, adds containers with `@(canvas_layout)` and graphics with `@(canvas_graphic)`.

## Components

- [Canvas](components/Canvas.md), the root of a UI tree: screen overlay, in front of a camera, or in the world.
- [RectTransform](components/RectTransform.md), a node's rect: anchors, size, pivot and position.
- [CanvasRenderer](components/CanvasRenderer.md) marks a node as drawing its graphic.
- [CanvasScaler](components/CanvasScaler.md) maps canvas units to screen pixels.
- [GraphicRaycaster](components/GraphicRaycaster.md) lets the pointer reach a canvas's graphics.

## Graphics

`Graphic` is not a component but the struct every drawable UI component embeds, as `using graphic: engine.Graphic` with the `inline:""` tag: `color`, `material` and `raycast_target`, saved under "graphic" and drawn flat in the inspector. A plugin declares a graphic type with `@(canvas_graphic)` on a `canvas_populate_<T>` proc, which takes the `^T` and returns the quads the component draws inside its rect. The generated registration records the component's type and where its Graphic sits, so the engine draws Image and Text through one path without knowing either type.

A quad a graphic returns can carry two things of its own:

- `material`, used when the graphic names none. A graphic that needs its own shader works with no setup this way.
- `properties`, values of that material's shader for this quad alone, by the names the shader's property block declares. They go over the material's values for the one draw (`Draw_Quad.properties`, `material_pack_draw_properties`). Quads with equal values share a draw call when they are neighbours in draw order, and a quad whose values differ is a draw call of its own. The mhgui Shape sends its size, radii and shadows this way.

## Position

`anchored_position` is the only stored value. The Transform API is a second door into it, so one call moves a bullet or a health bar:

- `transform_set_local_position` on a RectTransform node converts the position into `anchored_position`, and `transform_local_position` returns the value derived from it. Local positions are relative to the parent's pivot, in the parent's space. Z passes through as depth.
- `transform_world_position` and `transform_set_world_position` work on the canvas plane, the world space the Scene window shows: one unit per canvas unit, the canvas's bottom-left at the origin.
- The move gizmo and the Transform inspector's Position row go through these procs on UI nodes and record `anchored_position` for undo. The Transform's own position field is never read or written for UI, so scenes and prefab overrides carry no derived value.

## Drawing

The engine's canvas collector runs for Game windows and the Scene window. For each enabled canvas it resolves every active node's rect in draw order, and for each node with an enabled CanvasRenderer and a registered graphic emits one quad per quad the graphic returns, in the graphic's colour and material.

- **Draw order.** Nodes draw in hierarchy order, parents before children. A RectTransform's `z_index` changes that: a higher one draws over a lower one, whatever the hierarchy order. A node's `z_index` adds to its parent's, so a raised parent takes its children along. The pointer and the Scene window's picking follow the same order.
- **Game windows.** Quads sit on a plane just inside the camera's near plane, with the rect's pixel corners projected back through the camera, so they land on exactly those pixels for any camera and nothing in the scene draws in front of them.
- **Scene window.** The canvas is a world rect with its bottom-left at the origin in the XY plane, one world unit per canvas unit, sized like the last Game window, 1920 by 1080 before one has drawn.
- Sort keys use layer 127, the top of the transparent range, then the canvas's `sort_order`, then the node's place in the draw order.

## The pointer

Every frame, before any game update, `canvas_pointer_update` reads the mouse in viewport coordinates and raycasts the canvases with a GraphicRaycaster. The topmost graphic with `raycast_target` under the pointer is hovered. Pressing the left button remembers its node, as pressed and selected, and a release over the same node is a click for one frame. Nothing happens while the application has no focus. Components read `engine.ui_pointer()` instead of receiving events.

The selected node is the one keyboard and gamepad input acts on. A press selects the node it lands on, a press on nothing clears the selection, and `engine.ui_set_selected(node)` selects one from code. `engine.ui_selected()` reads it. The mhgui plugin's [Button](/plugins/mhgui/docs/components/Button.md) moves the selection with the arrow keys and the gamepad.
