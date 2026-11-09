---
title: "UI canvas"
description: "The canvas tree in the engine: Canvas, RectTransform, CanvasRenderer, CanvasScaler and GraphicRaycaster, rect layout, positions, drawing and the pointer"
weight: 60
tags: ["ui", "rendering", "components"]
path: engine/rendering
---

UI has two halves. The canvas tree is engine vocabulary, in `plugins/engine/ui_canvas.odin`: the components that lay out rects and the walk that resolves every node's rect. What gets drawn is content in plugins: the [mhgui](/plugins/mhgui/docs/_index.md) plugin's Image, Button and LayoutGroup, and the [text](/plugins/text/docs/_index.md) plugin's Text. Any plugin builds on the tree through `canvas_resolve_rects`, adds containers with `@(canvas_layout)` and graphics with `@(canvas_graphic)`.

## Components

- **Canvas**, the root of a UI tree, in one of three render modes:
  - Screen Space Overlay: the canvas rect is the game viewport in canvas units, drawn over everything. The node's transform is ignored.
  - Screen Space Camera: the same rect placed `plane_distance` in front of `render_camera`, facing it and scaled so its height spans the camera's view there, drawn by that camera with depth, so world objects can hide it. Without a camera it behaves as Overlay.
  - World Space: the node's RectTransform gives the size around its pivot, the node's transform places it, one canvas unit per world unit, drawn by every camera.
  - Canvases stack by `sort_order`. The Scene window shows all three modes where they sit in the world.
- **RectTransform**, the layout component, in canvas units with a bottom-left origin.
  - `anchor_min` and `anchor_max` pick a part of the parent rect. `size_delta` adds to that span: equal anchors give a fixed size, spread anchors stretch, and `size_delta` is then the margin.
  - `pivot` sits at the anchors' reference point plus `anchored_position`. Its third component is depth off the canvas plane.
  - The node's Transform rotation and scale apply around the pivot and compose down the hierarchy. A rotation around X or Y tilts the rect out of the canvas plane. The rect is still resolved in the parent's unrotated space, so anchors and layout keep their meaning.
  - A node without a RectTransform passes its parent's rect through.
- **CanvasRenderer** marks a node as drawing. What it draws comes from the node's graphic. Disabling it hides the graphic.
- **CanvasScaler**, on the Canvas node. Constant Pixel Size: one canvas unit is `scale_factor` screen pixels. Scale With Screen Size: the canvas is `reference_resolution` units, scaled to fit the screen, with `match` 0 fitting the width, 1 the height, and values between blending logarithmically. Without a scaler one canvas unit is one screen pixel.
- **GraphicRaycaster**, on the Canvas node. The pointer looks for graphics only in canvases that have one.

## Graphics

`Graphic` is not a component but the struct every drawable UI component embeds, as `using graphic: engine.Graphic` with the `inline:""` tag: `color`, `material` and `raycast_target`, saved under "graphic" and drawn flat in the inspector. A plugin declares a graphic type with `@(canvas_graphic)` on a `canvas_populate_<T>` proc, which takes the `^T` and returns the quads the component draws inside its rect. The generated registration records the component's type and where its Graphic sits, so the engine draws Image and Text through one path without knowing either type.

## Position

`anchored_position` is the only stored value. The Transform API is a second door into it, so one call moves a bullet or a health bar:

- `transform_set_local_position` on a RectTransform node converts the position into `anchored_position`, and `transform_local_position` returns the value derived from it. Local positions are relative to the parent's pivot, in the parent's space. Z passes through as depth.
- `transform_world_position` and `transform_set_world_position` work on the canvas plane, the world space the Scene window shows: one unit per canvas unit, the canvas's bottom-left at the origin.
- The move gizmo and the Transform inspector's Position row go through these procs on UI nodes and record `anchored_position` for undo. The Transform's own position field is never read or written for UI, so scenes and prefab overrides carry no derived value.

## Drawing

The engine's canvas collector runs for Game windows and the Scene window. For each enabled canvas it resolves every active node's rect in hierarchy order, parents before children, and for each node with an enabled CanvasRenderer and a registered graphic emits one quad per quad the graphic returns, in the graphic's colour and material.

- **Game windows.** Quads sit on a plane just inside the camera's near plane, with the rect's pixel corners projected back through the camera, so they land on exactly those pixels for any camera and nothing in the scene draws in front of them.
- **Scene window.** The canvas is a world rect with its bottom-left at the origin in the XY plane, one world unit per canvas unit, sized like the last Game window, 1920 by 1080 before one has drawn.
- Sort keys use layer 127, the top of the transparent range, then the canvas's `sort_order`, then the node's place in the walk.

## The pointer

Every frame, before any game update, `canvas_pointer_update` reads the mouse in viewport coordinates and raycasts the canvases with a GraphicRaycaster. The topmost graphic with `raycast_target` under the pointer is hovered. Pressing the left button remembers its node, as pressed and selected, and a release over the same node is a click for one frame. Nothing happens while the application has no focus. Components read `engine.ui_pointer()` instead of receiving events.

## The RectTransform inspector

For a single UI node the inspector hides the Transform section and draws the RectTransform this way (`scene_windows/rect_transform_drawer.odin`):

- The anchor preset button opens a 4 by 4 grid: left, center, right and stretch by top, middle, bottom and stretch. Shift also sets the pivot, Alt also moves the rect onto the anchors. The icons draw the actual anchors.
- Per axis the fields follow the anchors: Pos X and Width when the anchors coincide, Left and Right when they are apart, and the same for Y. Pos Z is the depth.
- Anchor and pivot edits keep the rect where it is. The [R] toggle is raw edit mode: only the values change, and the rect moves.
- Rotation and Scale are the Transform's rows.
- Every gesture is one undo step over the fields that changed. With several objects selected the rows show the active object's values with a dash where the others differ, and an edit writes the value into each object through its own anchors, pivot and parent, recording each object's prefab override.
- A rect a LayoutGroup lays out greys Pos X, Pos Y, Width and Height under "Some values driven by LayoutGroup".
