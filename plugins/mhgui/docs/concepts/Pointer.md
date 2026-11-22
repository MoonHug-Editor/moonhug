---
title: "The pointer"
description: "Pointer events for UI: what the pointer hits, touch, how a component takes the events, the rules and the polled record"
weight: 20
tags: ["mhgui", "pointer", "events", "touch", "concepts"]
---

The mhgui plugin's pointer pass: every frame it finds the UI node under each pointer and sends pointer events to the components on it. The code is `plugins/mhgui/pointer.odin` and `plugins/mhgui/raycast.odin`.

Every frame, before any game update, `canvas_pointer_update` reads the mouse in viewport coordinates, finds the topmost node under it across the canvases with a GraphicRaycaster, and sends pointer events. Nothing happens while the application has no focus.

## What the pointer hits

- A node is hit inside its rect. A graphic may narrow that with `@(canvas_hit)` on a proc named `canvas_hit_<T>`, which takes the component, the node's rect and a point of it and says whether the point hits. Every component on the node that has one must agree.
- The mhgui UiShape and UiPolygon are hit by their outlines, and an Image by its sprite's alpha when its `alpha_hit_threshold` is over 0.
- A node under a [UiMask](../components/UiMask.md) is hit only where the mask shows it: inside its rect and corners, and where its sprite's alpha is at least 0.1.

## Touch

Each finger on a touch screen is a pointer of its own. The mouse is pointer 0 and the fingers are 1 and up, in `ev.pointer`.

- A finger sends the same events as the mouse's left button: `Down`, `Hold`, `Drag_Begin`, `Drag`, `Up`, `Click`, `Cancel`. Every control works with it unchanged.
- Each finger has its own press, its own drag and its own double click, so two fingers hold two buttons, or move two sliders, at once.
- A finger hovers only while it is down: `Enter` comes with the touch and `Exit` when it lifts.
- On a touch screen the system also moves the mouse with the first finger. The pointer pass leaves the mouse out while that lasts, so a tap arrives once.
- A trackpad's fingers are no touches. They move the mouse.
- Game code reads fingers with `input.touches()`.

## Taking pointer events

Any component on a UI node takes the pointer events of that node with one proc. A control of the engine, a control of a plugin and a script of a game all use this one way:

```odin
@(comp_on_pointer_ui={component=Chest})
comp_on_pointer_ui_Chest :: proc(c: ^Chest, ev: ^mhgui.UI_Pointer_Event) {
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

## Events

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

## Rules

The same for every component:

- **Routing.** An event that goes "up" visits the node's parents in turn. A proc that sets `ev.used` stops it there.
- **Ownership.** The node that uses `Down` owns the pointer until the button comes up, and the hit node does when none uses it. `Up` reaches the owner wherever the pointer is, with `inside` saying whether it is still over it.
- **Click.** With an owner that used `Down`, the release must be over the owner or a node under it, and `Click` starts at the owner. So a button with a label and an icon clicks wherever on it the press and the release land. With no node using `Down`, `Click` starts at the nearest node that holds both the pressed and the released node.
- **Taking over a gesture.** Past the drag threshold (`mhgui.ui_drag_threshold`, 8 viewport pixels), `Drag_Begin` goes up from the pressed node. The first node that uses it owns the drag, and the owner before it gets `Cancel`. A scrolling list takes the drag from a button inside it this way, and a list that scrolls across leaves an up-and-down drag unused, so the list around it takes it. When no node uses `Drag_Begin` there is no drag, and the press can still click.
- **Keeping the drag.** A proc that sets `ev.own_drag` with `ev.used` on `Down` drags from the press itself: `Drag_Begin` comes at once with no threshold, and no parent takes the drag. A slider does this.
- **Scroll.** A scroller sets `ev.used` only when it moved, so at its limit the wheel reaches the scroller around it.
- **Hover.** A parent stays entered while the pointer is over its child. The chain holds still while a button is down and moves on the release.
- **Cancel is always sent.** A node that loses the pointer hears it: a parent took the drag, the application lost focus, or code called `mhgui.ui_pointer_cancel()`. After `Cancel` there is no `Up` and no `Click`.
- A second mouse button pressed during a press goes to the press's owner as `Down` and `Up` with its `button`.

## Reading the pointer

- `mhgui.ui_pointer_over_ui()` says whether the pointer is over UI or holds a press that began on it. Game code checks it so a click on a button is not also a shot in the world.
- `mhgui.ui_pointer()` is the polled record: the position, the hovered node, the press's owner, the selected node and the node clicked this frame with the left button.

The selected node is the one keyboard and gamepad input acts on. A press selects the node it lands on, a press on nothing clears the selection, and `mhgui.ui_set_selected(node)` selects one from code. `mhgui.ui_selected()` reads it. The mhgui plugin's [Button](/plugins/mhgui/docs/components/Button.md) moves the selection with the arrow keys and the gamepad.
