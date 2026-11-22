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

// The most pointers at once: the mouse and the fingers of a touch screen.
UI_MAX_POINTERS :: 1 + input.MAX_TOUCHES

// One pointer's state. Each pointer has its own press, hover chain and
// double click, so two fingers press two buttons at once.
@(private = "file")
_Pointer :: struct {
	id:         int,  // 0 is the mouse, 1 and up a finger
	touch:      u64,  // a finger's id in the input library
	used:       bool, // a finger's slot is taken
	press:      _Press,
	hover:      [dynamic]Transform_Handle, // the hit node first, then its parents
	last_click: struct {
		node:  Transform_Handle,
		time:  f64,
		count: int,
	},
	position:   [2]f32,
	hovered:    Transform_Handle,
}

@(private = "file")
_pointers: [UI_MAX_POINTERS]_Pointer
// The pointer whose events are being sent.
@(private = "file")
_cur: ^_Pointer

// What one pointer did this frame.
@(private = "file")
_Pointer_In :: struct {
	position: [2]f32,
	delta:    [2]f32,
	wheel:    f32,
	pressed:  [input.Mouse_Button]bool,
	released: [input.Mouse_Button]bool,
}

// Whether the pointer is over UI, or holds a press that began on it: game
// code checks it so a click on a button is not also a click in the world.
ui_pointer_over_ui :: proc() -> bool {
	for ptr in _pointers {
		if ptr.hovered != {} || (ptr.press.down && ptr.press.owner != {}) do return true
	}
	return false
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
	for &ptr in _pointers {
		if !ptr.press.down do continue
		_cur = &ptr
		if _cur.press.owner != {} {
			ev := _event(.Cancel, _cur.press.owner)
			_deliver(_cur.press.owner, &ev)
		}
		_cur.press = {}
	}
	_cur = &_pointers[0]
	_ui_pointer.pressed = {}
}

@(private = "file")
_event :: proc(kind: UI_Pointer_Kind, target: Transform_Handle) -> UI_Pointer_Event {
	ev := UI_Pointer_Event{
		kind           = kind,
		pointer        = _cur.id,
		button         = _cur.press.button,
		target         = target,
		position       = _cur.position,
		press_position = _cur.press.position,
	}
	if _cur.press.down do ev.held = f32(time.now(.Unscaled) - _cur.press.time)
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
	ev.inside = _cur.hovered != {} && transform_is_under(_cur.hovered, node)
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
	if _cur.hover == nil do _cur.hover = make([dynamic]Transform_Handle, runtime.default_allocator())
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
	old := make([]Transform_Handle, len(_cur.hover), context.temp_allocator)
	copy(old, _cur.hover[:])
	clear(&_cur.hover)
	append(&_cur.hover, ..chain[:])
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
//
// The mouse is pointer 0. Each finger on a touch screen is a pointer of its
// own, with the left button: it goes down, drags and clicks like the mouse,
// hovers only while it is down, and two fingers work two controls at once.
// While the system moves the mouse with a finger, the mouse is left out, so
// a finger's press arrives once.
canvas_pointer_update :: proc() {
	p := &_ui_pointer
	p.clicked = {}
	if !application_is_focused() {
		ui_pointer_cancel()
		p.hovered = {}
		for &ptr in _pointers {
			_cur = &ptr
			_cur.hovered = {}
			_hover_update({})
			ptr.used = false
		}
		_cur = &_pointers[0]
		return
	}
	// The mouse.
	_cur = &_pointers[0]
	finger_mouse := input.mouse_is_touch()
	mouse := _Pointer_In{position = input.mouse_position(), delta = input.mouse_delta(), wheel = input.wheel()}
	for button in input.Mouse_Button {
		mouse.pressed[button] = input.mouse_pressed(button) && !finger_mouse
		mouse.released[button] = input.mouse_released(button)
	}
	_pointer_step(mouse, over = !finger_mouse)

	// The fingers.
	for t in input.touches() {
		slot: ^_Pointer
		for &ptr, i in _pointers[1:] {
			if ptr.used && ptr.touch == t.id {
				slot = &ptr
				break
			}
			if slot == nil && !ptr.used && t.began {
				slot = &ptr
				slot.id = i + 1
			}
		}
		if slot == nil do continue
		if !slot.used {
			slot.used, slot.touch = true, t.id
			slot.press, slot.last_click = {}, {}
		}
		_cur = slot
		finger := _Pointer_In{position = t.position, delta = t.delta}
		finger.pressed[.Left] = t.began
		finger.released[.Left] = t.ended
		_pointer_step(finger, over = true)
		if t.ended {
			// A finger that is up is over nothing.
			_cur.hovered = {}
			_hover_update({})
			p.hovered = _pointers[0].hovered
			slot.used = false
		}
	}
	_cur = &_pointers[0]
}

// One pointer's frame: finds the node under it and sends its events. With
// `over` off the pointer is over nothing.
@(private = "file")
_pointer_step :: proc(input_now: _Pointer_In, over: bool) {
	p := &_ui_pointer
	w := ctx_world()
	_cur.position = input_now.position
	p.position = input_now.position
	hit := canvas_raycast(input_now.position, input.viewport_size()) if over else Transform_Handle{}
	_cur.hovered = hit
	p.hovered = hit
	// An owner that left the world takes its press with it.
	if _cur.press.down && _cur.press.owner != {} && !pool_valid(&w.transforms, Handle(_cur.press.owner)) do _cur.press = {}
	if !_cur.press.down do _hover_update(hit)

	// The press frame's mouse movement came before the press: it is no drag.
	pressed_now := false
	for button in input.Mouse_Button {
		if !input_now.pressed[button] do continue
		if _cur.press.down {
			// A second button during a press goes to the press's owner.
			if _cur.press.owner != {} {
				ev := _event(.Down, _cur.press.owner)
				ev.button = button
				_deliver(_cur.press.owner, &ev)
			}
			continue
		}
		pressed_now = true
		_cur.press = {down = true, button = button, hit = hit, position = p.position, time = time.now(.Unscaled)}
		if hit != {} {
			ev := _event(.Down, hit)
			taker := _bubble(hit, &ev)
			_cur.press.owner = taker if taker != {} else hit
			_cur.press.owner_used = taker != {}
			_cur.press.own_drag = taker != {} && ev.own_drag
		}
		if button == .Left do p.selected = _cur.press.owner
		if _cur.press.own_drag {
			begin := _event(.Drag_Begin, _cur.press.owner)
			_deliver(_cur.press.owner, &begin)
			_cur.press.dragging = true
		}
	}

	if _cur.press.down && _cur.press.owner != {} {
		delta := input_now.delta
		moved := p.position - _cur.press.position
		if !_cur.press.dragging && !_cur.press.drag_refused && linalg.length(moved) > ui_drag_threshold {
			ev := _event(.Drag_Begin, _cur.press.hit)
			ev.delta = moved
			taker := _bubble(_cur.press.hit, &ev)
			if taker == {} {
				_cur.press.drag_refused = true
			} else {
				if taker != _cur.press.owner {
					cancel := _event(.Cancel, _cur.press.owner)
					_deliver(_cur.press.owner, &cancel)
				}
				_cur.press.owner = taker
				_cur.press.owner_used = true
				_cur.press.dragging = true
			}
		} else if _cur.press.dragging && delta != {} && !pressed_now {
			ev := _event(.Drag, _cur.press.owner)
			ev.delta = delta
			_deliver(_cur.press.owner, &ev)
		}
		if _cur.press.down && !_cur.press.dragging {
			ev := _event(.Hold, _cur.press.owner)
			_deliver(_cur.press.owner, &ev)
		}
	}
	p.pressed = _cur.press.owner if _cur.press.down && !_cur.press.dragging else {}

	for button in input.Mouse_Button {
		if !input_now.released[button] || !_cur.press.down do continue
		if button != _cur.press.button {
			if _cur.press.owner != {} {
				ev := _event(.Up, _cur.press.owner)
				ev.button = button
				_deliver(_cur.press.owner, &ev)
			}
			continue
		}
		press := _cur.press
		if press.owner != {} {
			if press.dragging {
				end := _event(.Drag_End, press.owner)
				_deliver(press.owner, &end)
			}
			up := _event(.Up, press.owner)
			_bubble(press.owner, &up)
		}
		// The procs above may have cancelled the press.
		clicks := _cur.press.down && !press.dragging
		_cur.press = {}
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
				again := _cur.last_click.node == start && now - _cur.last_click.time <= UI_DOUBLE_CLICK_TIME
				_cur.last_click = {node = start, time = now, count = _cur.last_click.count + 1 if again else 1}
				ev := _event(.Click, start)
				ev.button = press.button
				ev.press_position = press.position
				ev.click_count = _cur.last_click.count
				taker := _bubble(start, &ev)
				if press.button == .Left do p.clicked = taker if taker != {} else start
			}
		}
		_hover_update(hit)
	}

	if wheel := input_now.wheel; wheel != 0 && hit != {} {
		ev := _event(.Scroll, hit)
		ev.scroll = {0, wheel}
		_bubble(hit, &ev)
	}
}

// Forgets the pointer's state: tests, and a world that was replaced.
ui_pointer_reset :: proc() {
	for &ptr, i in _pointers {
		hover := ptr.hover
		if hover != nil do clear(&hover)
		ptr = {id = i, hover = hover}
	}
	_cur = &_pointers[0]
	_ui_pointer = {}
}
