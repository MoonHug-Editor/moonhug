package mhgui

// Button: a clickable graphic with a selectable's colour transition. It takes
// the pointer events of its node (the engine pointer package) like any other
// component: it uses Down, so it owns the press, and Enter, Exit, Up, Cancel
// and Click set its hover, press and click state. From that state it tints
// its target graphic's CanvasRenderer with the matching color, fading over
// fade_duration. A click sets `clicked` for the rest of the frame, and game
// code polls button_clicked. The pointer must be able to hit the node or a
// node under it: a graphic with raycast_target on (Image, UiShape, Text) or a
// HitArea. A parent that takes the drag (a scroll view) cancels the press.
// A press dragged off the button looks let go, comes back when the pointer
// does, and does not click when released off it.
//
// Keyboard and gamepad act on the selected node (ui_selected: the
// last one pressed on, or the one code gave ui_set_selected):
// - The arrow keys, the d-pad and the left stick move the selection to the
//   nearest usable control in that direction. With nothing selected they do
//   nothing: a menu selects its first button when it opens.
// - A control's `navigation` changes that for the moves that start on it:
//   Explicit names the neighbour per direction, None keeps the selection on
//   it and keeps automatic moves off it (selectable.odin).
// - Enter, Space and the pad's bottom face button click the selected Button
//   and flip the selected Toggle. On a selected Slider the keys along its
//   axis change its value, and the keys across it move the selection.
// - ui_set_navigation(false) turns both off, for a game that uses those keys
//   while buttons are on screen.

import "core:math/linalg"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import "moonhug:libs/input"
import "moonhug:libs/time"

@(component={menu="UI/Button", icon="SMART_BUTTON"})
@(typ_guid={guid = "df76380d-f03d-4b86-9872-9f35af0d58e6"})
Button :: struct {
	using base:       engine.CompData `inspect:"-"`,
	// What every control shares (selectable.odin): interactable, the colour
	// transition and its state. Saved under "selectable", drawn flat.
	using selectable: Selectable `inline:""`,
	// Runtime state, never saved.
	clicked: bool `json:"-" inspect:"-"`, // clicked this frame, by the pointer or the submit key
}

// The Button's pointer events. It uses the left button's Down, which makes it
// the press's owner: Up and Click come back to it, and Cancel when a parent
// takes the drag.
@(comp_on_pointer={component=Button})
comp_on_pointer_Button :: proc(b: ^Button, ev: ^pointer.Pointer_Event) {
	selectable_pointer(&b.selectable, ev)
	if ev.kind == .Click && ev.button == .Left && selectable_usable(&b.selectable, b.owner) {
		b.clicked = true
		ev.used = true
	}
}

type_reset_Button :: proc(b: ^Button) {
	selectable_reset(&b.selectable)
}

// True on the frame the button was clicked. Read after ui_tick (any
// @(update) at order 0 or later).
button_clicked :: proc(b: ^Button) -> bool {
	return b.clicked
}

@(private = "file") _navigation := true
@(private = "file") _stick_was: [2]int // the left stick's direction last frame, to move once per push

// Whether keyboard and gamepad move the selection and click it. On by default.
ui_set_navigation :: proc(on: bool) {
	_navigation = on
}

ui_navigation :: proc() -> bool {
	return _navigation
}

@(private = "file") _keys_owner: engine.Transform_Handle

// A control that reads the keyboard itself takes the keys while it is the
// selected node: the arrow keys do not move the selection and the submit
// keys click nothing. A text field does while it is edited. {} gives them
// back.
ui_keys_capture :: proc(node: engine.Transform_Handle) {
	_keys_owner = node
}

// Whether a control has the keys now.
ui_keys_captured :: proc() -> bool {
	return _keys_owner != {} && _keys_owner == ui_selected()
}

// The submit keys went down this frame: Enter, Space or the gamepad's bottom
// face button.
ui_submit_pressed :: proc() -> bool {
	return _nav_submit_pressed()
}

// How far the left stick is pushed before it counts as a direction.
@(private = "file") _STICK_PUSH :: f32(0.5)

// The direction asked for this frame, in canvas axes (y up), {} for none.
@(private = "file")
_nav_move :: proc() -> [2]f32 {
	dir: [2]int
	if input.key_pressed(.LEFT) || input.gamepad_pressed(.DPAD_LEFT) do dir.x -= 1
	if input.key_pressed(.RIGHT) || input.gamepad_pressed(.DPAD_RIGHT) do dir.x += 1
	if input.key_pressed(.UP) || input.gamepad_pressed(.DPAD_UP) do dir.y += 1
	if input.key_pressed(.DOWN) || input.gamepad_pressed(.DPAD_DOWN) do dir.y -= 1
	// The stick's y is down-positive.
	sx, sy := input.gamepad_axis(.LEFTX), -input.gamepad_axis(.LEFTY)
	stick: [2]int
	if abs(sx) >= abs(sy) {
		if abs(sx) > _STICK_PUSH do stick.x = 1 if sx > 0 else -1
	} else if abs(sy) > _STICK_PUSH {
		stick.y = 1 if sy > 0 else -1
	}
	if stick != _stick_was && stick != {} && dir == {} do dir = stick
	_stick_was = stick
	// One axis per move: across wins a diagonal.
	if dir.x != 0 do return {f32(dir.x), 0}
	return {0, f32(dir.y)}
}

@(private = "file")
_nav_submit_pressed :: proc() -> bool {
	return input.key_pressed(.RETURN) || input.key_pressed(.KP_ENTER) || input.key_pressed(.SPACE) || input.gamepad_pressed(.SOUTH)
}

@(private = "file")
_nav_submit_down :: proc() -> bool {
	return input.key_down(.RETURN) || input.key_down(.KP_ENTER) || input.key_down(.SPACE) || input.gamepad_down(.SOUTH)
}

// A control keyboard and gamepad can reach: a Button, a Toggle or a Slider.
@(private = "file")
_usable :: proc(tH: engine.Transform_Handle) -> bool {
	sel, enabled := node_selectable(tH)
	return sel != nil && enabled && selectable_usable(sel, tH) && engine.transform_active_in_hierarchy(tH)
}

// Where a direction key takes the selection from `from`, by its navigation
// mode: the nearest control (Automatic), the named neighbour (Explicit) or
// nowhere (None). {} for no move.
ui_navigate_from :: proc(from: engine.Transform_Handle, dir: [2]f32) -> engine.Transform_Handle {
	sel, _ := node_selectable(from)
	if sel == nil do return {}
	switch sel.navigation.mode {
	case .Automatic:
		return button_find_in_direction(from, dir)
	case .Explicit:
		nav := &sel.navigation
		ref: engine.Ref_Local
		switch {
		case dir.x < 0: ref = nav.left
		case dir.x > 0: ref = nav.right
		case dir.y > 0: ref = nav.up
		case dir.y < 0: ref = nav.down
		}
		next := engine.Transform_Handle(ref.handle)
		if next == {} || next == from || !_usable(next) do return {}
		return next
	case .None:
	}
	return {}
}

// The usable control nearest to `from` in direction `dir` ({±1, 0} or
// {0, ±1}, y up), {} for none. A control with navigation None is no candidate. Buttons on overlay canvases compare in
// screen pixels, so the selection crosses from one overlay canvas to
// another. A canvas in the world or before a camera is its own space.
// A candidate scores by how far along `dir` it lies over its squared
// distance, measured from the edge of `from` that faces `dir`: near and
// straight ahead beats far or off to the side.
button_find_in_direction :: proc(from: engine.Transform_Handle, dir: [2]f32) -> engine.Transform_Handle {
	Spot :: struct {
		tH:     engine.Transform_Handle,
		space:  engine.Transform_Handle, // {} for the screen
		center: [2]f32,
		half:   [2]f32,
	}
	w := engine.ctx_world()
	screen := input.viewport_size()
	spots := make([dynamic]Spot, context.temp_allocator)
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&it) {
		if !canvas.enabled || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		root, _, in_world := engine.canvas_placement(canvas.owner, screen)
		scale := f32(1) if in_world else engine.canvas_scale(canvas.owner, screen)
		clear(&nodes)
		engine.canvas_resolve_rects(canvas.owner, root, &nodes)
		for n in nodes {
			sel, _ := node_selectable(n.tH)
			if sel == nil do continue
			if n.tH != from && (!_usable(n.tH) || sel.navigation.mode == .None) do continue
			c := engine.rect_corners(n.rect, n.xform)
			lo, hi := c[0].xy, c[0].xy
			for p in c[1:] {
				lo = linalg.min(lo, p.xy)
				hi = linalg.max(hi, p.xy)
			}
			append(&spots, Spot{n.tH, canvas.owner if in_world else {}, (lo + hi) * 0.5 * scale, (hi - lo) * 0.5 * scale})
		}
	}
	start: Spot
	for s in spots do if s.tH == from do start = s
	if start.tH == {} do return {}
	edge := start.center + dir * start.half
	best: engine.Transform_Handle
	best_score := f32(0)
	for s in spots {
		if s.tH == from || s.space != start.space do continue
		to := s.center - edge
		along := linalg.dot(to, dir)
		if along <= 0 do continue
		score := along / linalg.dot(to, to)
		if score > best_score {
			best = s.tH
			best_score = score
		}
	}
	return best
}

// Last frame's clicks and changes are over before the pointer pass
// (the pointer package's update, order -110) sets this frame's.
@(update={order=-120})
ui_frame_begin :: proc(dt: f32) {
	it := engine.pool_iterator(buttons(engine.ctx_world()))
	for b, _ in engine.pool_next(&it) do b.clicked = false
	toggles_frame_begin()
	sliders_frame_begin()
}

// After the pointer pass has sent this frame's pointer events: the selection
// a press makes, the keyboard and gamepad pass, then every Button's state
// and tint. Before the game's updates so they see this frame's clicks.
@(update={order=-100})
ui_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	// A press selects the UI node it lands on. On the world, or on nothing,
	// it clears the selection.
	if press := pointer.state(); press.began do ui_set_selected(press.began_on if press.began_source == .UI else {})
	submit, submit_down: bool
	if _navigation && engine.application_is_focused() && !ui_keys_captured() {
		selected := ui_selected()
		if dir := _nav_move(); dir != {} && selected != {} {
			// A selected Slider takes the keys along its own axis.
			if !slider_nav(selected, dir) {
				if next := ui_navigate_from(selected, dir); next != {} do ui_set_selected(next)
			}
		}
		submit = _nav_submit_pressed()
		submit_down = _nav_submit_down()
	}
	selected := ui_selected()
	// Real time: a menu responds while the game's time is slowed or held.
	real_dt := time.delta_time(.Unscaled)
	it := engine.pool_iterator(buttons(w))
	for b, _ in engine.pool_next(&it) {
		live := b.enabled && engine.transform_active_in_hierarchy(b.owner)
		chosen := live && selected == b.owner
		// The submit key clicks the selected Button. It is no pointer event.
		usable := live && selectable_usable(&b.selectable, b.owner)
		if usable && submit && chosen do b.clicked = true
		if !usable do b.clicked = false
		selectable_update(&b.selectable, b.owner, live, chosen, submit_down, real_dt)
	}
	toggles_update(selected, submit, submit_down, real_dt)
	sliders_update(selected, real_dt)
}
