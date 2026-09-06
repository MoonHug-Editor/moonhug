package mhgui

// Button: a clickable graphic with Unity's Selectable transition. The pointer
// pass (engine.canvas_pointer_update, run by ui_tick below before any game
// update) says which node is hovered, pressed, selected and clicked; every
// Button derives its state from that and tints its target graphic's
// CanvasRenderer with the matching color, fading over fade_duration. A click
// (press and release on the node) sets `clicked` for the rest of the frame;
// game code polls button_clicked. The node needs a graphic with
// raycast_target on (Image or Text) to be hit at all.

import "moonhug:engine"

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

// Unity's ColorBlock. Colors multiply the graphic's own color.
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
	clicked: bool             `json:"-" inspect:"-"`, // pressed and released on this node this frame
}

reset_Button :: proc(b: ^Button) {
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

// The pointer pass, then every Button's state and tint. Before the game's
// updates so they see this frame's clicks.
@(update={order=-100})
ui_tick :: proc(dt: f32) {
	engine.canvas_pointer_update()
	pointer := engine.ui_pointer()
	w := engine.ctx_world()
	it := engine.pool_iterator(buttons(w))
	for b, _ in engine.pool_next(&it) {
		if !b.enabled || !engine.transform_active_in_hierarchy(b.owner) {
			b.clicked = false
			continue
		}
		node := b.owner
		b.clicked = b.interactable && pointer.clicked == node
		switch {
		case !b.interactable:          b.state = .Disabled
		case pointer.pressed == node:  b.state = .Pressed
		case pointer.hovered == node:  b.state = .Highlighted
		case pointer.selected == node: b.state = .Selected
		case:                          b.state = .Normal
		}
		if b.transition == .Color_Tint do _button_tint(b, dt)
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
