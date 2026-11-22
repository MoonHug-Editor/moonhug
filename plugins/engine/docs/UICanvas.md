---
title: "UI canvas"
description: "The canvas tree in the engine: Canvas, RectTransform, CanvasRenderer, CanvasScaler, GraphicRaycaster and UiMask, rect layout, positions, drawing, clipping and the pointer"
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
- [UiMask](components/UiMask.md) clips the nodes under it to its rect.
- HitArea takes the pointer on its node's rect and draws nothing.

## Graphics

`Graphic` is not a component but the struct every drawable UI component embeds, as `using graphic: engine.Graphic` with the `inline:""` tag: `color`, `material` and `raycast_target`, saved under "graphic" and drawn flat in the inspector. A plugin declares a graphic type with `@(canvas_graphic)` on a `canvas_populate_<T>` proc, which takes the `^T` and returns the quads the component draws inside its rect. The generated registration records the component's type and where its Graphic sits, so the engine draws Image and Text through one path without knowing either type.

A quad a graphic returns can carry two things of its own:

- `material`, used when the graphic names none. A graphic that needs its own shader works with no setup this way.
- `properties`, values of that material's shader for this quad alone, by the names the shader's property block declares. They go over the material's values for the one draw (`Draw_Quad.properties`, `material_pack_draw_properties`). Quads with equal values share a draw call when they are neighbours in draw order, and a quad whose values differ is a draw call of its own. The mhgui UiShape sends its size, radii and shadows this way.

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
- **Clipping.** A quad of a node under a [UiMask](components/UiMask.md) carries the masks above it (`Draw_Quad.clip`): for each, the map from a pixel of the target into the mask's own space, its half size, its radii and its softness. The quad's shader cuts it to them. Nodes under the same masks share one list, so their quads merge. No stencil is used.
- Sort keys use layer 127, the top of the transparent range, then the canvas's `sort_order`, then the node's place in the draw order.

## The pointer

Every frame, before any game update, `canvas_pointer_update` reads the mouse in viewport coordinates, finds the topmost node under it across the canvases with a GraphicRaycaster, and sends pointer events. Nothing happens while the application has no focus.

### Taking pointer events

Any component on a UI node takes the pointer events of that node with one proc. A control of the engine, a control of a plugin and a script of a game all use this one way:

```odin
@(comp_on_pointer_ui={component=Chest})
comp_on_pointer_ui_Chest :: proc(c: ^Chest, ev: ^engine.UI_Pointer_Event) {
	#partial switch ev.kind {
	case .Click: chest_open(c)
	case .Enter: c.glow = true
	case .Exit:  c.glow = false
	}
}
```

What it works on:

- Components on a node inside a canvas that has a GraphicRaycaster.
- An event starts at a node the pointer can hit: one with a drawn graphic whose `raycast_target` is on, or one with a `HitArea`, a component that takes the pointer and draws nothing. It then goes to that node's parents, which need no graphic of their own. That is how a container hears about its children.
- It does not work on objects outside a canvas, such as a 3D object with a collider, nor on inactive nodes and disabled components.
- Keyboard and gamepad are not pointers and send none of these events.

### Events

| `ev.kind` | When | Goes to |
|---|---|---|
| `Enter`, `Exit` | The pointer came over the node or a node under it, or left | Each node that joined or left the chain from the hit node up |
| `Down` | A button went down | The hit node, then up |
| `Up` | The button came up | The press's owner, then up |
| `Click` | Pressed and released without a drag | See Click below |
| `Hold` | Every frame the button stays down, until a drag starts | The owner |
| `Drag_Begin` | The pointer moved past the drag threshold | The pressed node, then up |
| `Drag`, `Drag_End` | The pointer moved during a drag, the button came up | The drag's owner |
| `Scroll` | The wheel turned | The hit node, then up |
| `Cancel` | The node lost the pointer it owned | The owner |

The event carries `button`, `position` (viewport pixels, y down), `delta`, `press_position`, `scroll`, `click_count` (2 for a double click), `held` (seconds since the press, for a long press), `inside` (the pointer is over the node or a node under it), `node` (the node the proc's component is on) and `target` (the node the event started at). `ui_pointer_canvas_position(ev)` and `ui_pointer_canvas_delta(ev)` give the position and the movement in the canvas's own units with y up, in every canvas render mode: what a drag adds to an `anchored_position`.

### Rules

The same for every component:

- **Routing.** An event that goes "up" visits the node's parents in turn. A proc that sets `ev.used` stops it there.
- **Ownership.** The node that uses `Down` owns the pointer until the button comes up, and the hit node does when none uses it. `Up` reaches the owner wherever the pointer is, with `inside` saying whether it is still over it.
- **Click.** With an owner that used `Down`, the release must be over the owner or a node under it, and `Click` starts at the owner. So a button with a label and an icon clicks wherever on it the press and the release land. With no node using `Down`, `Click` starts at the nearest node that holds both the pressed and the released node.
- **Taking over a gesture.** Past the drag threshold (`engine.ui_drag_threshold`, 8 viewport pixels), `Drag_Begin` goes up from the pressed node. The first node that uses it owns the drag, and the owner before it gets `Cancel`. A scrolling list takes the drag from a button inside it this way, and a list that scrolls across leaves an up-and-down drag unused, so the list around it takes it. When no node uses `Drag_Begin` there is no drag, and the press can still click.
- **Keeping the drag.** A proc that sets `ev.own_drag` with `ev.used` on `Down` drags from the press itself: `Drag_Begin` comes at once with no threshold, and no parent takes the drag. A slider does this.
- **Scroll.** A scroller sets `ev.used` only when it moved, so at its limit the wheel reaches the scroller around it.
- **Hover.** A parent stays entered while the pointer is over its child. The chain holds still while a button is down and moves on the release.
- **Cancel is always sent.** A node that loses the pointer hears it: a parent took the drag, the application lost focus, or code called `engine.ui_pointer_cancel()`. After `Cancel` there is no `Up` and no `Click`.
- A second mouse button pressed during a press goes to the press's owner as `Down` and `Up` with its `button`.

### Reading the pointer

- `engine.ui_pointer_over_ui()` says whether the pointer is over UI or holds a press that began on it. Game code checks it so a click on a button is not also a shot in the world.
- `engine.ui_pointer()` is the polled record: the position, the hovered node, the press's owner, the selected node and the node clicked this frame with the left button.

The selected node is the one keyboard and gamepad input acts on. A press selects the node it lands on, a press on nothing clears the selection, and `engine.ui_set_selected(node)` selects one from code. `engine.ui_selected()` reads it. The mhgui plugin's [Button](/plugins/mhgui/docs/components/Button.md) moves the selection with the arrow keys and the gamepad.
