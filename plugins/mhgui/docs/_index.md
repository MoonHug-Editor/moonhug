---
title: "mhgui"
description: "UI graphics and controls on the engine's canvas tree: Image, Button and LayoutGroup, the UI menus and the rect tool"
tags: ["mhgui", "ui", "plugin"]
---

The mhgui plugin draws UI. It adds the Image graphic, the Button control and the LayoutGroup container on top of the engine's [canvas tree](/plugins/engine/docs/UICanvas.md), with the render collector that turns a canvas into quads, the GameObject, UI menus, and the rect tool that edits rects in the Scene window.

## What it adds

**Components**

- [Image](components/Image.md) draws a sprite or a solid colour in its rect, simple, 9-sliced or tiled.
- [Button](components/Button.md) tints a graphic as the pointer hovers and presses it, and reports clicks.
- [LayoutGroup](components/LayoutGroup.md) lays out its children in a row, a column or a grid.

**Concepts**

- [Editing UI](concepts/EditingUI.md): the UI menus, picking in the Scene window and the rect tool.

[Roadmap](Roadmap.md): the controls and features that come next.

## What it needs

- The engine plugin, whose canvas tree this plugin draws on: Canvas, RectTransform, CanvasRenderer, CanvasScaler and GraphicRaycaster ([UI canvas](/plugins/engine/docs/UICanvas.md)).
- Text is its own plugin, [text](/plugins/text/docs/_index.md). Neither the canvas tree nor mhgui knows about it.

## Quick start

1. GameObject, UI, Canvas: a canvas at the scene root, with a GraphicRaycaster.
2. GameObject, UI, Button: an Image with a Button under the canvas.
3. Set the RectTransform's anchors and size with the rect tool or the inspector, then press Play and click it.

## Building UI in code

Plain object and component creation: `transform_new`, then `transform_add_comp` for RectTransform, CanvasRenderer and the graphic, with the fields set directly. Text needs a font and the SDF material (`text.default_font_guid`, `text.default_material_guid`). The app's demo menu is built this way: `menu.scene` holds a canvas and a List with a vertical LayoutGroup, and `plugins/app/demo_menu.odin` adds one Text row per scene, each the graphic of a Button.

## Extending

The plugin declares no attributes. It uses the engine's: Image declares `@(canvas_graphic)` and LayoutGroup `@(canvas_layout)`, which is how another plugin adds a graphic or a container ([UI canvas](/plugins/engine/docs/UICanvas.md), "Graphics").

## Limits

- One control, Button, with a colour tint transition. No toggle, slider, scroll view, input field or dropdown ([Roadmap](Roadmap.md)).
- No clipping and no masks.
- Pointer only, no keyboard or gamepad navigation.

## Reference

- [API reference](/docs/reference/packages/mhgui/mhgui.md) of the `mhgui` package.
