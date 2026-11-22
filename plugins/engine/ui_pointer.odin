package engine

// Pointer events for UI: one mechanism for every component on a canvas node.
//
// A component takes them with one proc:
//
//   @(comp_on_pointer_ui={component=MyWidget})
//   comp_on_pointer_ui_MyWidget :: proc(w: ^MyWidget, ev: ^engine.UI_Pointer_Event) {
//       #partial switch ev.kind {
//       case .Click: ...
//       }
//   }
//
// What it works on:
// - Components on a node inside a canvas that has a GraphicRaycaster.
// - An event starts at a node the pointer can hit: one with a graphic whose
//   raycast_target is on, or a HitArea. It then goes to that node's parents,
//   which need no graphic of their own.
// - Not objects outside a canvas, and not inactive nodes or disabled
//   components.
//
// The rules, the same for every component:
// - Routing. The topmost hit node gets the event first, then each parent. A
//   proc that sets ev.used stops it there.
// - Ownership. The node that uses Down owns the pointer until the button
//   comes up, the hit node when none does. Up goes to the owner wherever the
//   pointer is, and Hold goes to it every frame the button stays down.
// - Click. On release, when the press was not dragged. With an owner that
//   used Down: the release must be over the owner or a node under it, and
//   Click starts at the owner. Otherwise it starts at the nearest node that
//   holds both the pressed and the released node.
// - Taking over a gesture. Once the pointer moves past the drag threshold,
//   Drag_Begin goes up from the pressed node. The first node that uses it
//   owns the drag: it gets Drag and Drag_End, and the owner before it gets
//   Cancel. When no node uses it, there is no drag and the press can still
//   click. A proc that sets ev.own_drag on Down keeps the drag: it starts at
//   once, with no threshold, and no parent takes it (a slider).
// - Scroll. The wheel goes up from the hit node. A scroller uses it only when
//   it moved, so the rest reaches the scroller around it.
// - Hover. Enter and Exit go to the nodes that joined or left the chain from
//   the hit node up, so a parent stays entered over its child. The chain
//   holds still while a button is down.
// - Cancel. A node that loses the pointer always hears it: a parent took the
//   drag, the application lost focus, or code called ui_pointer_cancel.
//
// Keyboard and gamepad are not pointers and send none of these.

import "base:runtime"
import "core:math/linalg"
import "moonhug:libs/input"
import "moonhug:libs/time"

UI_Pointer_Kind :: enum u8 {
	Enter,      // the pointer came over the node or a node under it
	Exit,
	Down,       // a button went down over the node
	Up,         // the button came up: to the owner, wherever the pointer is
	Click,      // pressed and released without a drag
	Hold,       // every frame the button stays down, to the owner. `held` is how long
	Drag_Begin, // the pointer moved past the threshold: use it to take the drag
	Drag,       // the pointer moved, to the drag's owner
	Drag_End,
	Scroll,     // the wheel turned over the node
	Cancel,     // the node lost the pointer it owned
}

UI_Pointer_Event :: struct {
	kind:           UI_Pointer_Kind,
	pointer:        int,                // which pointer: 0 is the mouse
	button:         input.Mouse_Button,
	node:           Transform_Handle,   // the node the proc's component is on
	target:         Transform_Handle,   // the node the event started at
	position:       [2]f32,             // viewport pixels, y down
	delta:          [2]f32,             // movement since the last frame. Drag_Begin: since the press
	press_position: [2]f32,             // where the button went down
	scroll:         [2]f32,             // Scroll: the wheel's turn, y up
	click_count:    int,                // Click: 2 for a double click
	held:           f32,                // seconds since the button went down
	inside:         bool,               // the pointer is over `node` or a node under it
	// Set by the proc: no parent gets this event.
	used:           bool,
	// Set by the proc on Down, with `used`: the node drags from this press
	// with no threshold and no parent takes the drag.
	own_drag:       bool,
}

UI_Pointer_Proc :: proc(comp: rawptr, ev: ^UI_Pointer_Event)

// Runs a proc on a component for every pointer event of its node: the node
// was hit, or a node under it was and no proc below used the event.
// `component = T` names a @(component) type of the same package, and the proc
// is `proc(c: ^T, ev: ^engine.UI_Pointer_Event)`, named
// `comp_on_pointer_ui_<T>`. A type has at most one. UI nodes only: see the
// top of this file for what it works on.
@(extension_point={attribute="comp_on_pointer_ui", target="proc", fields="component"})
ui_pointer_procs: [TypeKey]UI_Pointer_Proc

ui_pointer_register :: proc(key: TypeKey, fn: UI_Pointer_Proc) {
	ui_pointer_procs[key] = fn
}

// How far the pointer moves from the press before it is a drag, in viewport
// pixels.
ui_drag_threshold: f32 = 8

// Two clicks on one node within this many seconds are a double click.
UI_DOUBLE_CLICK_TIME :: 0.4

@(private = "file")
_Press :: struct {
	down:         bool,
	button:       input.Mouse_Button,
	hit:          Transform_Handle, // the node under the pointer at the press
	owner:        Transform_Handle,
	owner_used:   bool, // a proc used Down
	own_drag:     bool,
	position:     [2]f32,
	time:         f64,
	dragging:     bool,
	drag_refused: bool, // no node took Drag_Begin: the press stays a click
}

@(private = "file")
_press: _Press
// The hover chain, the hit node first, then its parents.
@(private = "file")
_hover: [dynamic]Transform_Handle
@(private = "file")
_last_click: struct {
	node:  Transform_Handle,
	time:  f64,
	count: int,
}

// Whether the pointer is over UI, or holds a press that began on it: game
// code checks it so a click on a button is not also a click in the world.
ui_pointer_over_ui :: proc() -> bool {
	return _ui_pointer.hovered != {} || (_press.down && _press.owner != {})
}

// The pointer's position on the canvas of the event's node, in canvas units
// with y up: what a control compares with its rect. False off the canvas's
// plane.
ui_pointer_canvas_position :: proc(ev: ^UI_Pointer_Event) -> ([2]f32, bool) {
	canvas := canvas_of(ev.node)
	if canvas == {} do return {}, false
	return canvas_point_at(canvas, ev.position, input.viewport_size())
}

// The event's movement in the canvas units of its node, y up: what a drag
// adds to an anchored position, whatever the canvas scale or render mode.
ui_pointer_canvas_delta :: proc(ev: ^UI_Pointer_Event) -> [2]f32 {
	canvas := canvas_of(ev.node)
	if canvas == {} do return {}
	viewport := input.viewport_size()
	now, ok_now := canvas_point_at(canvas, ev.position, viewport)
	was, ok_was := canvas_point_at(canvas, ev.position - ev.delta, viewport)
	if !ok_now || !ok_was do return {}
	return now - was
}

// Takes the pointer from the node that owns it: the owner gets Cancel, and
// the press ends with no Up and no Click.
ui_pointer_cancel :: proc() {
	if !_press.down do return
	if _press.owner != {} {
		ev := _event(.Cancel, _press.owner)
		_deliver(_press.owner, &ev)
	}
	_press = {}
	_ui_pointer.pressed = {}
}

@(private = "file")
_event :: proc(kind: UI_Pointer_Kind, target: Transform_Handle) -> UI_Pointer_Event {
	ev := UI_Pointer_Event{
		kind           = kind,
		button         = _press.button,
		target         = target,
		position       = _ui_pointer.position,
		press_position = _press.position,
	}
	if _press.down do ev.held = f32(time.now(.Unscaled) - _press.time)
	return ev
}

// Runs the pointer procs of one node's components.
@(private = "file")
_deliver :: proc(node: Transform_Handle, ev: ^UI_Pointer_Event) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(node))
	if t == nil || !transform_active_in_hierarchy(node) do return
	// A proc may add or remove components: the list is walked as it was.
	owned := make([]Handle, len(t.components), context.temp_allocator)
	for c, i in t.components do owned[i] = c.handle
	ev.node = node
	ev.inside = _ui_pointer.hovered != {} && transform_is_under(_ui_pointer.hovered, node)
	for h in owned {
		fn := ui_pointer_procs[h.type_key]
		if fn == nil do continue
		c := world_pool_get(w, h)
		if c == nil || !(cast(^CompData)c).enabled do continue
		fn(c, ev)
	}
}

// Sends the event to `start`, then to each parent, until a proc uses it.
// Returns the node that did, {} for none.
@(private = "file")
_bubble :: proc(start: Transform_Handle, ev: ^UI_Pointer_Event) -> Transform_Handle {
	w := ctx_world()
	node := start
	for _ in 0 ..< 4096 {
		t := pool_get(&w.transforms, Handle(node))
		if t == nil do return {}
		parent := Transform_Handle(t.parent.handle)
		_deliver(node, ev)
		if ev.used do return node
		if parent == {} do return {}
		node = parent
	}
	return {}
}

// The nearest node that holds both `a` and `b`, {} for none.
@(private = "file")
_common_ancestor :: proc(a, b: Transform_Handle) -> Transform_Handle {
	if a == {} || b == {} do return {}
	w := ctx_world()
	node := a
	for _ in 0 ..< 4096 {
		if transform_is_under(b, node) do return node
		t := pool_get(&w.transforms, Handle(node))
		if t == nil || t.parent.handle == {} do return {}
		node = Transform_Handle(t.parent.handle)
	}
	return {}
}

// Moves the hover chain to `hit`: Exit for the nodes that left it, the
// deepest first, then Enter for the ones that joined, the highest first.
@(private = "file")
_hover_update :: proc(hit: Transform_Handle) {
	if _hover == nil do _hover = make([dynamic]Transform_Handle, runtime.default_allocator())
	w := ctx_world()
	chain := make([dynamic]Transform_Handle, context.temp_allocator)
	for node, n := hit, 0; node != {} && n < 4096; n += 1 {
		t := pool_get(&w.transforms, Handle(node))
		if t == nil do break
		append(&chain, node)
		node = Transform_Handle(t.parent.handle)
	}
	contains :: proc(list: []Transform_Handle, h: Transform_Handle) -> bool {
		for e in list do if e == h do return true
		return false
	}
	old := make([]Transform_Handle, len(_hover), context.temp_allocator)
	copy(old, _hover[:])
	clear(&_hover)
	append(&_hover, ..chain[:])
	for node in old {
		if contains(chain[:], node) do continue
		ev := _event(.Exit, hit)
		_deliver(node, &ev)
	}
	#reverse for node in chain {
		if contains(old, node) do continue
		ev := _event(.Enter, hit)
		_deliver(node, &ev)
	}
}

// The pointer pass, once a frame before the game's updates (the mhgui
// package's ui_tick runs it): reads the mouse, finds the node under it and
// sends the events above. It also keeps the polled record (ui_pointer).
canvas_pointer_update :: proc() {
	p := &_ui_pointer
	p.clicked = {}
	if !application_is_focused() {
		ui_pointer_cancel()
		p.hovered = {}
		_hover_update({})
		return
	}
	w := ctx_world()
	p.position = input.mouse_position()
	hit := canvas_raycast(p.position, input.viewport_size())
	p.hovered = hit
	// An owner that left the world takes its press with it.
	if _press.down && _press.owner != {} && !pool_valid(&w.transforms, Handle(_press.owner)) do _press = {}
	if !_press.down do _hover_update(hit)

	// The press frame's mouse movement came before the press: it is no drag.
	pressed_now := false
	for button in input.Mouse_Button {
		if !input.mouse_pressed(button) do continue
		if _press.down {
			// A second button during a press goes to the press's owner.
			if _press.owner != {} {
				ev := _event(.Down, _press.owner)
				ev.button = button
				_deliver(_press.owner, &ev)
			}
			continue
		}
		pressed_now = true
		_press = {down = true, button = button, hit = hit, position = p.position, time = time.now(.Unscaled)}
		if hit != {} {
			ev := _event(.Down, hit)
			taker := _bubble(hit, &ev)
			_press.owner = taker if taker != {} else hit
			_press.owner_used = taker != {}
			_press.own_drag = taker != {} && ev.own_drag
		}
		if button == .Left do p.selected = _press.owner
		if _press.own_drag {
			begin := _event(.Drag_Begin, _press.owner)
			_deliver(_press.owner, &begin)
			_press.dragging = true
		}
	}

	if _press.down && _press.owner != {} {
		delta := input.mouse_delta()
		moved := p.position - _press.position
		if !_press.dragging && !_press.drag_refused && linalg.length(moved) > ui_drag_threshold {
			ev := _event(.Drag_Begin, _press.hit)
			ev.delta = moved
			taker := _bubble(_press.hit, &ev)
			if taker == {} {
				_press.drag_refused = true
			} else {
				if taker != _press.owner {
					cancel := _event(.Cancel, _press.owner)
					_deliver(_press.owner, &cancel)
				}
				_press.owner = taker
				_press.owner_used = true
				_press.dragging = true
			}
		} else if _press.dragging && delta != {} && !pressed_now {
			ev := _event(.Drag, _press.owner)
			ev.delta = delta
			_deliver(_press.owner, &ev)
		}
		if _press.down && !_press.dragging {
			ev := _event(.Hold, _press.owner)
			_deliver(_press.owner, &ev)
		}
	}
	p.pressed = _press.owner if _press.down && !_press.dragging else {}

	for button in input.Mouse_Button {
		if !input.mouse_released(button) || !_press.down do continue
		if button != _press.button {
			if _press.owner != {} {
				ev := _event(.Up, _press.owner)
				ev.button = button
				_deliver(_press.owner, &ev)
			}
			continue
		}
		press := _press
		if press.owner != {} {
			if press.dragging {
				end := _event(.Drag_End, press.owner)
				_deliver(press.owner, &end)
			}
			up := _event(.Up, press.owner)
			_bubble(press.owner, &up)
		}
		// The procs above may have cancelled the press.
		clicks := _press.down && !press.dragging
		_press = {}
		p.pressed = {}
		if clicks {
			start: Transform_Handle
			if press.owner_used {
				if hit != {} && transform_is_under(hit, press.owner) do start = press.owner
			} else {
				start = _common_ancestor(press.hit, hit)
			}
			if start != {} {
				now := time.now(.Unscaled)
				again := _last_click.node == start && now - _last_click.time <= UI_DOUBLE_CLICK_TIME
				_last_click = {node = start, time = now, count = _last_click.count + 1 if again else 1}
				ev := _event(.Click, start)
				ev.button = press.button
				ev.press_position = press.position
				ev.click_count = _last_click.count
				taker := _bubble(start, &ev)
				if press.button == .Left do p.clicked = taker if taker != {} else start
			}
		}
		_hover_update(hit)
	}

	if wheel := input.wheel(); wheel != 0 && hit != {} {
		ev := _event(.Scroll, hit)
		ev.scroll = {0, wheel}
		_bubble(hit, &ev)
	}
}

// Forgets the pointer's state: tests, and a world that was replaced.
ui_pointer_reset :: proc() {
	_press = {}
	_last_click = {}
	if _hover != nil do clear(&_hover)
	_ui_pointer = {}
}
