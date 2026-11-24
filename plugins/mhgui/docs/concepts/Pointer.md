---
title: "The pointer on UI"
description: "What the pointer hits on a canvas, hit tests by shape, and the selected node"
weight: 20
tags: ["mhgui", "pointer", "events", "concepts"]
---

Pointer events are the engine's: a component takes them with `@(comp_on_pointer)`, on a UI node or on an object in the world, by the rules in [Pointer events](/plugins/engine/docs/Pointer.md). This plugin adds the UI side: the raycast that finds the canvas node under the pointer, and the selected node. The code is `plugins/mhgui/raycast.odin`.

## What the pointer hits

- A node is hit inside its rect. A graphic may narrow that with `@(canvas_hit)` on a proc named `canvas_hit_<T>`, which takes the component, the node's rect and a point of it and says whether the point hits. Every component on the node that has one must agree.
- The mhgui UiShape and UiPolygon are hit by their outlines, and an Image by its sprite's alpha when its `alpha_hit_threshold` is over 0.
- A node under a [UiMask](../components/UiMask.md) is hit only where the mask shows it: inside its rect and corners, and where its sprite's alpha is at least 0.1.

## Which nodes get events

- Components on a node inside a canvas that has a [GraphicRaycaster](../components/GraphicRaycaster.md).
- An event starts at a node the pointer can hit: one with a drawn graphic whose `raycast_target` is on, or one with a `HitArea`, a component that takes the pointer and draws nothing. It then goes to that node's parents, which need no graphic of their own. That is how a container hears about its children.
- UI comes first: a pointer over a canvas's graphic hits nothing in the world behind it.
- `pointer.canvas_position(ev)` and `pointer.canvas_delta(ev)` give the event's position and movement in the canvas's own units with y up, in every canvas render mode: what a drag adds to an `anchored_position`.

## The selected node

The selected node is the one keyboard and gamepad input acts on. A press selects the UI node it lands on, a press on the world or on nothing clears the selection, and `mhgui.ui_set_selected(node)` selects one from code. `mhgui.ui_selected()` reads it. The [Button](/plugins/mhgui/docs/components/Button.md) moves the selection with the arrow keys and the gamepad.

## The frame

Three updates run in this order, before the game's:

| Order | Proc | What it does |
|---|---|---|
| -120 | `mhgui.ui_frame_begin` | Clears last frame's clicks and changes |
| -110 | the pointer package's `pointer_update` | Sends this frame's pointer events |
| -100 | `mhgui.ui_tick` | The selection a press makes, keyboard and gamepad, every control's look |
