---
title: "mhgui"
description: "UI graphics and controls on the engine's canvas tree: Image, UiShape, Button, Toggle, Slider, ScrollRect, Scrollbar and LayoutGroup, the UI menus and the rect tool"
tags: ["mhgui", "ui", "plugin"]
---

The mhgui plugin draws UI. It adds the Image and UiShape graphics, the Button control and the LayoutGroup container on top of the engine's [canvas tree](/plugins/engine/docs/UICanvas.md), with the render collector that turns a canvas into quads, the GameObject, UI menus, and the rect tool that edits rects in the Scene window.

## What it adds

**Components**

- [Image](components/Image.md) draws a sprite or a solid colour in its rect, simple, 9-sliced, tiled or filled by an amount.
- [RawImage](components/RawImage.md) draws a texture, whole or a part of it.
- [UiShape](components/UiShape.md) draws a rounded rectangle, an ellipse, a polygon or a star with a border, a gradient and shadows, with no sprite.
- [UiPolygon](components/UiPolygon.md) draws an outline given by points, filled or as a line.
- [UiGradient](components/UiGradient.md), [UiShadow](components/UiShadow.md) and [UiOutline](components/UiOutline.md) are effects for any graphic.
- [UiMask](components/UiMask.md) clips the nodes under it to its rect, its round corners or a sprite's alpha.
- [CanvasScaler](components/CanvasScaler.md) maps canvas units to screen pixels.
- [GraphicRaycaster](components/GraphicRaycaster.md) lets the pointer reach a canvas's graphics, and HitArea takes the pointer on a rect that draws nothing.
- [Button](components/Button.md) tints a graphic as the pointer hovers and presses it, takes keyboard and gamepad input while selected, and reports clicks.
- [Toggle](components/Toggle.md) is on or off, and a ToggleGroup keeps one toggle of a set on.
- [Slider](components/Slider.md) sets a number by dragging a handle along a track.
- [ScrollRect](components/ScrollRect.md) scrolls a content node inside a viewport, by a drag, the wheel or a scrollbar.
- [Scrollbar](components/Scrollbar.md) is a track with a handle that shows a place and sets it.
- [LayoutGroup](components/LayoutGroup.md) lays out its children in a row, a column or a grid.
- [LayoutElement](components/LayoutElement.md) says what a node asks of the LayoutGroup that places it.
- [ContentSizeFitter](components/ContentSizeFitter.md) sizes a node to its text or its children.
- [AspectRatioFitter](components/AspectRatioFitter.md) keeps a node at a width to height ratio.

**Concepts**

- [The pointer on UI](concepts/Pointer.md): what the pointer hits on a canvas, hit tests by shape, and the selected node.
- [Editing UI](concepts/EditingUI.md): the UI menus, picking in the Scene window and the rect tool.

[Roadmap](Roadmap.md): the controls and features that come next.

## What it needs

- The engine plugin, whose canvas tree this plugin draws on: Canvas, RectTransform, CanvasRenderer and CanvasGroup ([UI canvas](/plugins/engine/docs/UICanvas.md)). The scaler, the masks, the raycaster and [the pointer](concepts/Pointer.md) are this plugin's.
- Text is its own plugin, [text](/plugins/text/docs/_index.md), which builds on this one: it holds the Text graphic and the controls made of text, InputField and Dropdown. mhgui does not know about it.

## Quick start

1. GameObject, UI, Canvas: a canvas at the scene root, with a GraphicRaycaster.
2. GameObject, UI, Button: an Image with a Button under the canvas.
3. Set the RectTransform's anchors and size with the rect tool or the inspector, then press Play and click it.

## Building UI in code

Plain object and component creation: `transform_new`, then `transform_add_comp` for RectTransform, CanvasRenderer and the graphic, with the fields set directly. Text needs a font and the SDF material (`text.default_font_guid`, `text.default_material_guid`). The app's demo menu is built this way: `demo_menu.scene` holds a canvas and a List with a vertical LayoutGroup, and `plugins/app/demo_menu.odin` adds one Text row per scene, each the graphic of a Button.

## Extending

The plugin declares one attribute, in [The pointer on UI](concepts/Pointer.md):

- `@(canvas_hit)`: a graphic says whether a point of its rect hits it.

Its controls take the pointer with the engine's `@(comp_on_pointer)` ([Pointer events](/plugins/engine/docs/Pointer.md)), and so does a control another plugin or a game adds.

It uses the engine's for drawing and layout: its graphics declare `@(canvas_graphic)`, its effects `@(canvas_effect)`, LayoutGroup `@(canvas_layout)` and the two fitters `@(canvas_rect)`, which is how another plugin adds a graphic or a container ([UI canvas](/plugins/engine/docs/UICanvas.md), "Graphics").

## Limits

- The controls here are Button, Toggle, Slider, ScrollRect and Scrollbar. InputField and Dropdown are the [text](/plugins/text/docs/_index.md) plugin's.
- What is not built is in the [Roadmap](Roadmap.md).

## Reference

- [API reference](/docs/reference/packages/mhgui/mhgui.md) of the `mhgui` package.
