package mhgui

// What every control shares: whether it can be used, and the look that
// follows the pointer and the selection. Button, Toggle and Slider embed it
// as `using selectable: Selectable` with the `inline:""` tag, so its fields
// are saved under "selectable" and drawn flat in the inspector.
//
// A control feeds its pointer events to selectable_pointer and is updated
// once a frame (ui_tick). From the hover, the press and the selection the
// Selectable picks a state and tints the target graphic's CanvasRenderer
// with that state's color, fading over fade_duration.

import "moonhug:packages/engine"

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

Selectable :: struct {
	interactable:   bool,
	transition:     Selectable_Transition,
	target_graphic: engine.Ref_Local `ref:"Transform"`, // the node whose graphic takes the tint; empty = this node
	colors:         Color_Block,
	// Runtime state, never saved.
	state:   Selectable_State `json:"-" inspect:"-"`,
	hovered: bool             `json:"-" inspect:"-"`, // the pointer is over the node or a node under it
	pressed: bool             `json:"-" inspect:"-"`, // the pointer's left button is down on it
	// During a press: the pointer is still over the control. Dragged off it,
	// the control looks let go, and a release there does not click.
	pressed_inside: bool      `json:"-" inspect:"-"`,
}

selectable_reset :: proc(s: ^Selectable) {
	s.interactable = true
	s.transition = .Color_Tint
	s.colors = Color_Block{
		normal           = {1, 1, 1, 1},
		highlighted      = {0.96, 0.96, 0.96, 1},
		pressed          = {0.78, 0.78, 0.78, 1},
		selected         = {0.96, 0.96, 0.96, 1},
		disabled         = {0.78, 0.78, 0.78, 0.5},
		color_multiplier = 1,
		fade_duration    = 0.1,
	}
}

// The part of a control's pointer events that is the same for all: the
// hover, and the left button's press. It uses Down, which makes the control
// the press's owner: Up and Click come back to it, and Cancel when a parent
// takes the drag. The control handles Click itself.
selectable_pointer :: proc(s: ^Selectable, ev: ^engine.UI_Pointer_Event) {
	#partial switch ev.kind {
	case .Enter: s.hovered = true
	case .Exit:  s.hovered = false
	case .Down:
		if ev.button != .Left || !s.interactable do return
		s.pressed, s.pressed_inside = true, true
		ev.used = true
	case .Hold:
		s.pressed_inside = ev.inside
	case .Up:
		if ev.button == .Left do s.pressed = false
	case .Cancel:
		s.pressed = false
	}
}

// Once a frame: the state from the hover, the press and the selection, and
// the tint. `live` is false for a disabled component or an inactive node,
// `chosen` says the node is the selected one, `held` that the submit key is
// down on it.
selectable_update :: proc(s: ^Selectable, owner: engine.Transform_Handle, live, chosen, held: bool, dt: f32) {
	if !live {
		s.hovered, s.pressed, s.pressed_inside = false, false, false
		return
	}
	switch {
	case !s.interactable:               s.state = .Disabled
	case s.pressed && s.pressed_inside: s.state = .Pressed
	case held && chosen:                s.state = .Pressed
	// Pressed and dragged off: it looks as it does with no pointer on it.
	case s.pressed:                     s.state = .Selected if chosen else .Normal
	case s.hovered:                     s.state = .Highlighted
	case chosen:                        s.state = .Selected
	case:                               s.state = .Normal
	}
	if s.transition != .Color_Tint do return
	target_tH := engine.Transform_Handle(s.target_graphic.handle)
	if target_tH == {} do target_tH = owner
	_, cr := engine.transform_get_comp(target_tH, engine.CanvasRenderer)
	if cr == nil do return
	c := s.colors
	want: [4]f32
	switch s.state {
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

// The Selectable of the control on a node (a Button, a Toggle or a Slider)
// and whether that component is enabled. nil for a node with none.
node_selectable :: proc(tH: engine.Transform_Handle) -> (sel: ^Selectable, enabled: bool) {
	if _, b := engine.transform_get_comp(tH, Button); b != nil do return &b.selectable, b.enabled
	if _, t := engine.transform_get_comp(tH, Toggle); t != nil do return &t.selectable, t.enabled
	if _, s := engine.transform_get_comp(tH, Slider); s != nil do return &s.selectable, s.enabled
	return nil, false
}
