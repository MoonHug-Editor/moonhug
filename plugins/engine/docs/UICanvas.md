---
title: "UI canvas"
description: "The canvas tree in the engine: Canvas, RectTransform, CanvasRenderer and CanvasGroup, rect layout, positions, drawing, and what a plugin installs on it"
weight: 60
tags: ["ui", "rendering", "components"]
path: engine/concepts/rendering
---

UI has two halves. The canvas tree is engine vocabulary, in `plugins/engine/ui_canvas.odin`: the components that lay out rects and the walk that resolves every node's rect. What gets drawn is content in plugins: the [mhgui](/plugins/mhgui/docs/_index.md) plugin's Image, Button and LayoutGroup, and the [text](/plugins/text/docs/_index.md) plugin's Text. Any plugin builds on the tree through `canvas_resolve_rects`, adds containers with `@(canvas_layout)` and graphics with `@(canvas_graphic)`.

## Components

- [Canvas](components/Canvas.md), the root of a UI tree: screen overlay, in front of a camera, or in the world.
- [RectTransform](components/RectTransform.md), a node's rect: anchors, size, pivot and position.
- [CanvasRenderer](components/CanvasRenderer.md) marks a node as drawing its graphic.
- [CanvasGroup](components/CanvasGroup.md) fades a whole subtree and turns it off for the pointer.

The rest of UI is the [mhgui](/plugins/mhgui/docs/_index.md) plugin's, built on these: the graphics and controls, [CanvasScaler](/plugins/mhgui/docs/components/CanvasScaler.md), [UiMask](/plugins/mhgui/docs/components/UiMask.md), [GraphicRaycaster](/plugins/mhgui/docs/components/GraphicRaycaster.md), HitArea and the selected node. A node takes the pointer with the engine's [pointer events](Pointer.md).

## What a plugin installs

The engine draws the tree and asks a plugin for two things it does not decide itself. Each is installed once, from an `@(init)` proc:

- `engine.canvas_scale_install(proc)`: how many screen pixels a canvas unit is, for a canvas and a screen size. With none installed the scale is 1. The mhgui CanvasScaler installs it.
- `engine.canvas_clip_install(provider)`: which mask a node is under, and the masks above it in a view as gfx clips to them. With none installed nothing is clipped. The mhgui UiMask installs it.

## Graphics

`Graphic` is not a component but the struct every drawable UI component embeds, as `using graphic: engine.Graphic` with the `inline:""` tag: `color`, `material` and `raycast_target`, saved under "graphic" and drawn flat in the inspector. A plugin declares a graphic type with `@(canvas_graphic)` on a `canvas_populate_<T>` proc, which takes the `^T` and returns the quads the component draws inside its rect. The generated registration records the component's type and where its Graphic sits, so the engine draws Image and Text through one path without knowing either type.

A quad a graphic returns can carry these things of its own:

- `material`, used when the graphic names none. A graphic that needs its own shader works with no setup this way.
- `properties`, values of that material's shader for this quad alone, by the names the shader's property block declares. They go over the material's values for the one draw (`Draw_Quad.properties`, `material_pack_draw_properties`). Quads with equal values share a draw call when they are neighbours in draw order, and a quad whose values differ is a draw call of its own. The mhgui UiShape sends its size, radii and shadows this way.
- `corners` with `free` set: any four points in place of a rect. This is how a graphic draws a mesh: a triangle is a quad with two corners at one point, and `engine.graphic_triangle` appends one. The mhgui Filled Image and UiPolygon draw this way.
- `colors` with `colored` set: a colour per corner, which multiplies the graphic's colour. The colour runs smoothly between the corners.
- `absolute`: the quad's colours stand as they are, and only the alpha of the graphic's colour applies. A shadow behind a graphic keeps its own colour this way.

## Rects

A node's rect comes from its RectTransform and its parent's rect. Three things in a plugin can change that, each declared with an attribute on a proc:

- `@(canvas_layout)`: a container places its children. Asked for every node with its rect and its RectTransform children. The mhgui LayoutGroup is one.
- `@(canvas_rect)`: a component sets its own node's rect. Asked for every node that resolves from its own anchors, with its parent's rect and the rect the anchors gave. The mhgui ContentSizeFitter and AspectRatioFitter are one. A node a container placed is not asked.
- `@(canvas_effect)`: a component changes the quads of the graphic on its node after the graphic made them, on a proc named `canvas_effect_<T>` that takes the component, the node's rect and the quads. A shadow adds copies behind them, a gradient colours their corners. Effects on one node run in the order of its components. The mhgui plugin's UiGradient, UiShadow and UiOutline are effects.
- `@(canvas_measure)`: a component says how large it wants its node, on a proc named `canvas_measure_<T>` that takes the component and the width to fit in. `engine.node_measure(node, width)` reads it. The text plugin's Text has one.

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
- **Clipping.** A quad of a node under a mask (the mhgui [UiMask](/plugins/mhgui/docs/components/UiMask.md), through the installed clip provider) carries the masks above it (`Draw_Quad.clip`): for each, the map from a pixel of the target into the mask's own space, its half size, its radii and its softness. The quad's shader cuts it to them. Nodes under the same masks share one list, so their quads merge. No stencil is used.
- Sort keys use layer 127, the top of the transparent range, then the canvas's `sort_order`, then the node's place in the draw order.

## What a canvas keeps

The collector runs for every view of every frame: the Scene window, the Game window, each camera. Most of its work for a canvas gives the same answer each time, so a canvas keeps it: every node's resolved rect, each graphic's quads, and the effects run over them. A collect with nothing changed only places the kept quads in its view.

The kept answer is used while nothing it came from changed:

- **A fingerprint of the canvas's subtree.** Every node's transform and whether it is active, and the contents of every component on it, strings and lists by what they hold. Setting a field from game code, an animation, the inspector or an undo changes it. There is no call to make and no setter to go through.
- **The screen size** the canvas is laid out for.
- **`engine.canvas_content_changed()`**, for what no component holds. The texture cache calls it when a texture loads or unloads, and the text plugin when a font does.

A graphic whose quads depend on something outside its node's components, the time or a global, calls `engine.canvas_content_changed()` when that changes. A graphic that draws from its own fields needs nothing.

- A canvas with something moving in it collects afresh each frame, as before. Put what changes every frame on a canvas of its own and the rest stays kept.
- A component that counts time in one of its fields while it rests makes its canvas collect afresh every frame. The plugin's controls do not.
- `engine.canvas_rebuilds` counts the fresh collects.
