---
title: "Pointer events"
description: "Pointer events for any object: what finds the object under the pointer, touch, how a component takes the events, the rules and the polled record"
weight: 30
tags: ["engine", "pointer", "events", "touch", "attributes"]
path: engine/concepts/frame
---

The pointer pass: every frame it finds the object under each pointer and sends pointer events to the components on it. The mouse and each finger of a touch screen are pointers. A component takes the events with one proc, whatever the object is: a UI node, or an object in the world with a collider. The code is the engine's `pointer` package, `plugins/engine/pointer`.

## Taking pointer events

```odin
import pointer "moonhug:packages/engine/pointer"

@(comp_on_pointer={component=Chest})
comp_on_pointer_Chest :: proc(c: ^Chest, ev: ^pointer.Pointer_Event) {
	#partial switch ev.kind {
	case .Click: chest_open(c)
	case .Enter: c.glow = true
	case .Exit:  c.glow = false
	}
}
```

- `component = T` names a `@(component)` type of the same package, and the proc is named `comp_on_pointer_<T>`. A type has at most one.
- The package is in a build when something imports it, which this proc does for its event type. Its own `@(update)` proc runs the pointer pass, at order -110, so nothing calls it. A game with no such proc carries none of it.
- An update that reads what a pointer proc set runs after the pass, with an order above -110.
- It does not work on inactive objects and disabled components.
- Keyboard and gamepad are not pointers and send none of these events.
- Nothing happens while the application has no focus.

## What finds the object

`@(comp_on_pointer)` names the reaction. What finds the object under the pointer is a separate thing, a raycaster:

| Raycaster | Goes on | Finds |
|---|---|---|
| [GraphicRaycaster](/plugins/mhgui/docs/components/GraphicRaycaster.md) | a Canvas | UI nodes, with the mhgui plugin |
| [PhysicsRaycaster](/plugins/physics3d/docs/components/PhysicsRaycaster.md) | a Camera | 3D colliders, with the physics3d plugin |
| [Physics2DRaycaster](/plugins/physics2d/docs/components/Physics2DRaycaster.md) | a Camera | 2D colliders, with the physics2d plugin |

- A door with a collider and a component that has a `@(comp_on_pointer)` proc opens on `Click`, with a PhysicsRaycaster on the camera. The same component on a UI node works unchanged.
- The event goes to the object that was hit and then up its parents, so a collider on a child clicks its parent's component.
- `ev.source` says what found the object: `UI`, `World_3D` or `World_2D`. `ev.world_position` and `ev.world_normal` are where the collider under the pointer is hit, and zero over UI.
- A plugin adds its own way to find objects with `@(pointer_raycaster)` on a proc that takes a viewport point and answers with the object there and how far it is. The proc usually walks a component of its own that says where to look.
- `order` says when a raycaster is asked, the lowest first, 0 when left out. A later order is asked only when no raycaster of the earlier ones hits.
- The UI's order is -100 (`pointer.ORDER_UI`), before the world's 0: a pointer over a canvas's graphic hits nothing in the world behind it.
- Among raycasters of one order the nearest hit wins.

```odin
@(pointer_raycaster)
pointer_raycast :: proc(position: [2]f32, viewport: [2]f32) -> (hit: pointer.Pointer_Hit, ok: bool) { ... }
```

## Touch

Each finger on a touch screen is a pointer of its own. The mouse is pointer 0 and the fingers are 1 and up, in `ev.pointer`.

- A finger sends the same events as the mouse's left button: `Down`, `Hold`, `Drag_Begin`, `Drag`, `Up`, `Click`, `Cancel`. Every control works with it unchanged.
- Each finger has its own press, its own drag and its own double click, so two fingers hold two buttons, or move two sliders, at once.
- A finger hovers only while it is down: `Enter` comes with the touch and `Exit` when it lifts.
- On a touch screen the system also moves the mouse with the first finger. The pointer pass leaves the mouse out while that lasts, so a tap arrives once.
- A trackpad's fingers are no touches. They move the mouse.
- Game code reads fingers with `input.touches()`.

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

The event carries `button`, `position` (viewport pixels, y down), `delta`, `press_position`, `scroll`, `click_count` (2 for a double click), `held` (seconds since the press, for a long press), `inside` (the pointer is over the node or a node under it), `node` (the node the proc's component is on) and `target` (the node the event started at). `pointer.canvas_position(ev)` and `pointer.canvas_delta(ev)` give, for a UI node, the position and the movement in the canvas's own units with y up, in every canvas render mode: what a drag adds to an `anchored_position`.

## Rules

The same for every component:

- **Routing.** An event that goes "up" visits the node's parents in turn. A proc that sets `ev.used` stops it there.
- **Ownership.** The node that uses `Down` owns the pointer until the button comes up, and the hit node does when none uses it. `Up` reaches the owner wherever the pointer is, with `inside` saying whether it is still over it.
- **Click.** With an owner that used `Down`, the release must be over the owner or a node under it, and `Click` starts at the owner. So a button with a label and an icon clicks wherever on it the press and the release land. With no node using `Down`, `Click` starts at the nearest node that holds both the pressed and the released node.
- **Taking over a gesture.** Past the drag threshold (`pointer.drag_threshold`, 8 viewport pixels), `Drag_Begin` goes up from the pressed node. The first node that uses it owns the drag, and the owner before it gets `Cancel`. A scrolling list takes the drag from a button inside it this way, and a list that scrolls across leaves an up-and-down drag unused, so the list around it takes it. When no node uses `Drag_Begin` there is no drag, and the press can still click.
- **Keeping the drag.** A proc that sets `ev.own_drag` with `ev.used` on `Down` drags from the press itself: `Drag_Begin` comes at once with no threshold, and no parent takes the drag. A slider does this.
- **Scroll.** A scroller sets `ev.used` only when it moved, so at its limit the wheel reaches the scroller around it.
- **Hover.** A parent stays entered while the pointer is over its child. The chain holds still while a button is down and moves on the release.
- **Cancel is always sent.** A node that loses the pointer hears it: a parent took the drag, the application lost focus, or code called `pointer.cancel()`. After `Cancel` there is no `Up` and no `Click`.
- A second mouse button pressed during a press goes to the press's owner as `Down` and `Up` with its `button`.

## Reading the pointer

- `pointer.over(.UI)` says whether a pointer is over UI or holds a press that began on it. A collider under the pointer does not count. Game code checks it so a click on a button is not also a shot in the world. `over(.World_3D)` and `over(.World_2D)` ask the same of the world.
- `pointer.state()` is the polled record: the position, the hovered object, the press's owner, the object clicked this frame with the left button, and whether the left button went down this frame and on what.
- `pointer.hit_at(position, viewport)` is the object under any viewport point.
