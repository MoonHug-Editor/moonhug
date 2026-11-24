package mhgui

// Slider: a control that sets a number between two ends by dragging a handle
// along a track. The Slider's node is the track. `fill` names the node that
// covers the track from its start up to the value, `handle` the node that
// sits at the value. The Slider places both by their anchors along the
// track, so their size and position along it are not theirs to set.
//
// It keeps the drag from its own press: a list around it does not scroll
// while the handle is dragged. While it is selected, the keys along its axis
// change the value.
//
// It is a Selectable (selectable.odin): it tints its target graphic with the
// pointer, as a Button does.

import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import "moonhug:libs/input"

Slider_Direction :: enum u8 {
	Left_To_Right, // the least value at the left
	Right_To_Left,
	Bottom_To_Top,
	Top_To_Bottom,
}

@(component={menu="UI/Slider"})
@(typ_guid={guid = "7a7488cb-9843-4f9e-8243-f5f212c39801"})
Slider :: struct {
	using base:       engine.CompData `inspect:"-"`,
	using selectable: Selectable `inline:""`,
	fill:          engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node that covers the track from its start to the value.")`,
	handle:        engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node that sits at the value.")`,
	direction:     Slider_Direction,
	min_value:     f32,
	max_value:     f32,
	whole_numbers: bool `decor:tooltip(desc="The value is a whole number.")`,
	value:         f32,
	// Runtime state, never saved.
	changed:  bool `json:"-" inspect:"-"`, // the value changed this frame
	dragging: bool `json:"-" inspect:"-"`,
}

type_reset_Slider :: proc(s: ^Slider) {
	selectable_reset(&s.selectable)
	s.min_value = 0
	s.max_value = 1
}

// True on the frame the value changed. Read after ui_tick (any @(update) at
// order 0 or later).
slider_changed :: proc(s: ^Slider) -> bool {
	return s.changed
}

// Sets the value, kept between the ends and whole when the slider says so.
// `changed` is set when it is another value than before.
slider_set :: proc(s: ^Slider, value: f32) {
	lo, hi := min(s.min_value, s.max_value), max(s.min_value, s.max_value)
	v := clamp(value, lo, hi)
	if s.whole_numbers do v = math.round(v)
	if v != s.value {
		s.value = v
		s.changed = true
	}
	_slider_place(s)
}

// Where the value is between the ends, 0 to 1.
slider_normalized :: proc(s: ^Slider) -> f32 {
	if s.max_value == s.min_value do return 0
	return clamp((s.value - s.min_value) / (s.max_value - s.min_value), 0, 1)
}

@(private = "file")
_vertical :: proc(s: ^Slider) -> bool {
	return s.direction == .Bottom_To_Top || s.direction == .Top_To_Bottom
}

@(private = "file")
_reversed :: proc(s: ^Slider) -> bool {
	return s.direction == .Right_To_Left || s.direction == .Top_To_Bottom
}

// Places the fill and the handle by their anchors, from the value.
@(private = "file")
_slider_place :: proc(s: ^Slider) {
	n := slider_normalized(s)
	at := 1 - n if _reversed(s) else n
	vertical := _vertical(s)
	if _, rt := engine.transform_get_comp(engine.Transform_Handle(s.fill.handle), engine.RectTransform); rt != nil {
		lo, hi := f32(0), at
		if _reversed(s) do lo, hi = at, 1
		if vertical {
			rt.anchor_min, rt.anchor_max = {rt.anchor_min.x, lo}, {rt.anchor_max.x, hi}
			rt.size_delta.y, rt.anchored_position.y = 0, 0
		} else {
			rt.anchor_min, rt.anchor_max = {lo, rt.anchor_min.y}, {hi, rt.anchor_max.y}
			rt.size_delta.x, rt.anchored_position.x = 0, 0
		}
	}
	if _, rt := engine.transform_get_comp(engine.Transform_Handle(s.handle.handle), engine.RectTransform); rt != nil {
		// A point on the track: the handle keeps its own size around it.
		if vertical {
			rt.anchor_min, rt.anchor_max = {rt.anchor_min.x, at}, {rt.anchor_max.x, at}
			rt.anchored_position.y = 0
		} else {
			rt.anchor_min, rt.anchor_max = {at, rt.anchor_min.y}, {at, rt.anchor_max.y}
			rt.anchored_position.x = 0
		}
	}
}

// Where the pointer is along the track, 0 to 1 from its start.
@(private = "file")
_pointer_along :: proc(s: ^Slider, ev: ^pointer.Pointer_Event) -> (at: f32, ok: bool) {
	canvas := engine.canvas_of(s.owner)
	if canvas == {} do return
	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	for n in nodes {
		if n.tH != s.owner do continue
		p := pointer.canvas_position(ev) or_return
		local := (linalg.inverse(n.xform) * [4]f32{p.x, p.y, 0, 1}).xy
		length := n.rect.size.y if _vertical(s) else n.rect.size.x
		if length <= 0 do return
		along := (local.y - n.rect.pos.y) if _vertical(s) else (local.x - n.rect.pos.x)
		return clamp(along / length, 0, 1), true
	}
	return
}

@(private = "file")
_slider_to_pointer :: proc(s: ^Slider, ev: ^pointer.Pointer_Event) {
	at, ok := _pointer_along(s, ev)
	if !ok do return
	n := 1 - at if _reversed(s) else at
	slider_set(s, s.min_value + (s.max_value - s.min_value) * n)
}

// The press goes to the pointer's place on the track and the drag follows
// it. The Slider keeps the drag: no list above takes it.
@(comp_on_pointer={component=Slider})
comp_on_pointer_Slider :: proc(s: ^Slider, ev: ^pointer.Pointer_Event) {
	selectable_pointer(&s.selectable, ev)
	#partial switch ev.kind {
	case .Down:
		if ev.button != .Left || !selectable_usable(&s.selectable, s.owner) do return
		ev.own_drag = true
		s.dragging = true
		_slider_to_pointer(s, ev)
	case .Drag:
		if s.dragging do _slider_to_pointer(s, ev)
	case .Up, .Cancel, .Drag_End:
		s.dragging = false
	}
}

// The step a key moves the value by: 1 for whole numbers, else a tenth of
// the range.
@(private = "file")
_slider_step :: proc(s: ^Slider) -> f32 {
	if s.whole_numbers do return 1
	return (s.max_value - s.min_value) * 0.1
}

// A direction key on the selected node (ui_tick): a Slider takes the keys
// along its own axis and changes its value. False leaves the key to move
// the selection: the node is no usable Slider, or the key runs across it.
slider_nav :: proc(selected: engine.Transform_Handle, dir: [2]f32) -> bool {
	_, s := engine.transform_get_comp(selected, Slider)
	if s == nil || !s.enabled || !selectable_usable(&s.selectable, selected) do return false
	along := dir.y if _vertical(s) else dir.x
	if along == 0 do return false
	if _reversed(s) do along = -along
	slider_set(s, s.value + along * _slider_step(s))
	return true
}

// ui_tick: last frame's changes are over.
sliders_frame_begin :: proc() {
	it := engine.pool_iterator(sliders(engine.ctx_world()))
	for s, _ in engine.pool_next(&it) do s.changed = false
}

// ui_tick: every Slider's fill and handle follow its value, set by the
// pointer, a key or code, then its look.
sliders_update :: proc(selected: engine.Transform_Handle, dt: f32) {
	it := engine.pool_iterator(sliders(engine.ctx_world()))
	for s, _ in engine.pool_next(&it) {
		live := s.enabled && engine.transform_active_in_hierarchy(s.owner)
		if live do _slider_place(s)
		selectable_update(&s.selectable, s.owner, live, live && selected == s.owner, false, dt)
	}
}
