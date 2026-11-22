package mhgui

// Button: a clickable graphic with a selectable's colour transition. It takes
// the pointer events of its node (engine/ui_pointer.odin) like any other
// component: it uses Down, so it owns the press, and Enter, Exit, Up, Cancel
// and Click set its hover, press and click state. From that state it tints
// its target graphic's CanvasRenderer with the matching color, fading over
// fade_duration. A click sets `clicked` for the rest of the frame, and game
// code polls button_clicked. The pointer must be able to hit the node or a
// node under it: a graphic with raycast_target on (Image, Shape, Text) or a
// HitArea. A parent that takes the drag (a scroll view) cancels the press.
//
// Keyboard and gamepad act on the selected node (engine.ui_selected: the
// last one pressed on, or the one code gave engine.ui_set_selected):
// - The arrow keys, the d-pad and the left stick move the selection to the
//   nearest usable Button in that direction. With nothing selected they do
//   nothing: a menu selects its first button when it opens.
// - Enter, Space and the pad's bottom face button click the selected Button.
// - ui_set_navigation(false) turns both off, for a game that uses those keys
//   while buttons are on screen.

import "core:math/linalg"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import "moonhug:libs/time"

Selectable_Transition :: enum u8 {
	None,
	Color_Tint,
}

Selectable_State :: enum u8 {
	Normal,
	Highlighted,
	Pressed,
	Selected,
	Disabled,
}

// The colour per state. Colors multiply the graphic's own color.
Color_Block :: struct {
	normal:           [4]f32 `decor:color()`,
	highlighted:      [4]f32 `decor:color()`,
	pressed:          [4]f32 `decor:color()`,
	selected:         [4]f32 `decor:color()`,
	disabled:         [4]f32 `decor:color()`,
	color_multiplier: f32,
	fade_duration:    f32, // seconds
}

@(component={menu="UI/Button"})
@(typ_guid={guid = "df76380d-f03d-4b86-9872-9f35af0d58e6"})
Button :: struct {
	using base:     engine.CompData `inspect:"-"`,
	interactable:   bool,
	transition:     Selectable_Transition,
	target_graphic: engine.Ref_Local `ref:"Transform"`, // the node whose graphic takes the tint; empty = this node
	colors:         Color_Block,
	// Runtime state, never saved.
	state:   Selectable_State `json:"-" inspect:"-"`,
	clicked: bool             `json:"-" inspect:"-"`, // clicked this frame, by the pointer or the submit key
	hovered: bool             `json:"-" inspect:"-"`, // the pointer is over the node or a node under it
	pressed: bool             `json:"-" inspect:"-"`, // the pointer's left button is down on it
}

// The Button's pointer events. It uses the left button's Down, which makes it
// the press's owner: Up and Click come back to it, and Cancel when a parent
// takes the drag.
@(comp_on_pointer_ui={component=Button})
comp_on_pointer_ui_Button :: proc(b: ^Button, ev: ^engine.UI_Pointer_Event) {
	#partial switch ev.kind {
	case .Enter: b.hovered = true
	case .Exit:  b.hovered = false
	case .Down:
		if ev.button != .Left || !b.interactable do return
		b.pressed = true
		ev.used = true
	case .Up:
		if ev.button == .Left do b.pressed = false
	case .Cancel:
		b.pressed = false
	case .Click:
		if ev.button != .Left || !b.interactable do return
		b.clicked = true
		ev.used = true
	}
}

type_reset_Button :: proc(b: ^Button) {
	b.interactable = true
	b.transition = .Color_Tint
	b.colors = Color_Block{
		normal           = {1, 1, 1, 1},
		highlighted      = {0.96, 0.96, 0.96, 1},
		pressed          = {0.78, 0.78, 0.78, 1},
		selected         = {0.96, 0.96, 0.96, 1},
		disabled         = {0.78, 0.78, 0.78, 0.5},
		color_multiplier = 1,
		fade_duration    = 0.1,
	}
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

// A Button keyboard and gamepad can reach.
@(private = "file")
_usable :: proc(tH: engine.Transform_Handle) -> bool {
	_, b := engine.transform_get_comp(tH, Button)
	return b != nil && b.enabled && b.interactable && engine.transform_active_in_hierarchy(tH)
}

// The usable Button nearest to `from` in direction `dir` ({±1, 0} or
// {0, ±1}, y up), {} for none. Buttons on overlay canvases compare in
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
			if n.tH != from && !_usable(n.tH) do continue
			if n.tH == from {
				if _, b := engine.transform_get_comp(n.tH, Button); b == nil do continue
			}
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

// The pointer pass, which sends this frame's pointer events, the keyboard and
// gamepad pass, then every Button's state and tint. Before the game's updates
// so they see this frame's clicks.
@(update={order=-100})
ui_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	// Last frame's clicks are over before the pointer pass sets this frame's.
	{
		it := engine.pool_iterator(buttons(w))
		for b, _ in engine.pool_next(&it) do b.clicked = false
	}
	engine.canvas_pointer_update()
	submit, submit_down: bool
	if _navigation && engine.application_is_focused() {
		selected := engine.ui_selected()
		if dir := _nav_move(); dir != {} && selected != {} {
			if next := button_find_in_direction(selected, dir); next != {} do engine.ui_set_selected(next)
		}
		submit = _nav_submit_pressed()
		submit_down = _nav_submit_down()
	}
	selected := engine.ui_selected()
	it := engine.pool_iterator(buttons(w))
	for b, _ in engine.pool_next(&it) {
		if !b.enabled || !engine.transform_active_in_hierarchy(b.owner) {
			b.clicked, b.hovered, b.pressed = false, false, false
			continue
		}
		chosen := selected == b.owner
		// The submit key clicks the selected Button. It is no pointer event.
		if b.interactable && submit && chosen do b.clicked = true
		if !b.interactable do b.clicked = false
		switch {
		case !b.interactable:       b.state = .Disabled
		case b.pressed:             b.state = .Pressed
		case submit_down && chosen: b.state = .Pressed
		case b.hovered:             b.state = .Highlighted
		case chosen:                b.state = .Selected
		case:                       b.state = .Normal
		}
		// Real time: a menu responds while the game's time is slowed or held.
		if b.transition == .Color_Tint do _button_tint(b, time.delta_time(.Unscaled))
	}
}

@(private = "file")
_button_tint :: proc(b: ^Button, dt: f32) {
	target_tH := engine.Transform_Handle(b.target_graphic.handle)
	if target_tH == {} do target_tH = b.owner
	_, cr := engine.transform_get_comp(target_tH, engine.CanvasRenderer)
	if cr == nil do return
	c := b.colors
	want: [4]f32
	switch b.state {
	case .Normal:      want = c.normal
	case .Highlighted: want = c.highlighted
	case .Pressed:     want = c.pressed
	case .Selected:    want = c.selected
	case .Disabled:    want = c.disabled
	}
	want *= c.color_multiplier
	if !cr.tinted || c.fade_duration <= 0 {
		engine.canvas_renderer_set_tint(cr, want)
		return
	}
	// Move a fraction of the way each frame: done within fade_duration.
	t := min(dt / c.fade_duration, 1)
	engine.canvas_renderer_set_tint(cr, cr.tint + (want - cr.tint) * t)
}
