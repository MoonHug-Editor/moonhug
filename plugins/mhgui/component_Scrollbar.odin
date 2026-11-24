package mhgui

// Scrollbar: a track with a handle that shows a place between two ends and
// how much shows of what is there, and sets the place when the pointer drags
// the handle or presses the track. A ScrollRect drives one per axis
// (component_ScrollRect.odin). On its own it is a control with a `value`.
//
// The handle is a node under the Scrollbar's node. The Scrollbar places it:
// it sets the handle's anchors along the track, so the handle's own size and
// position along it are not its to set.

import "core:math/linalg"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import "moonhug:libs/input"

Scrollbar_Direction :: enum u8 {
	Left_To_Right, // value 0 at the left
	Right_To_Left,
	Bottom_To_Top, // value 0 at the bottom: 1 is the top, as a ScrollRect's up and down is
	Top_To_Bottom,
}

@(component={menu="UI/Scrollbar"})
@(typ_guid={guid = "86a0269e-7429-4b05-af43-6ad20df46638"})
Scrollbar :: struct {
	using base: engine.CompData `inspect:"-"`,
	handle:     engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node that slides along the track, a child of this one.")`,
	direction:  Scrollbar_Direction,
	value:      f32 `decor:range(0, 1) decor:tooltip(desc="The place between the ends, 0 to 1.")`,
	size:       f32 `decor:range(0, 1) decor:tooltip(desc="The handle's length as a share of the track: how much shows.")`,
	min_handle: f32 `decor:min(0) decor:tooltip(desc="The shortest the handle gets, in canvas units, so it stays easy to grab.")`,
	// Runtime state, never saved.
	dragging: bool `json:"-" inspect:"-"`,
	changed:  bool `json:"-" inspect:"-"`, // the pointer moved the value: a ScrollRect takes it
	grab:     f32  `json:"-" inspect:"-"`, // where on the handle the drag holds it, 0 to 1
}

type_reset_Scrollbar :: proc(b: ^Scrollbar) {
	b.direction = .Bottom_To_Top
	b.value = 1
	b.size = 0.2
	b.min_handle = 20
}

// Sets what the bar shows, and places the handle.
scrollbar_set :: proc(b: ^Scrollbar, value, size: f32) {
	b.value = clamp(value, 0, 1)
	b.size = clamp(size, 0, 1)
	_scrollbar_place(b)
}

@(private = "file")
_vertical :: proc(b: ^Scrollbar) -> bool {
	return b.direction == .Bottom_To_Top || b.direction == .Top_To_Bottom
}

@(private = "file")
_reversed :: proc(b: ^Scrollbar) -> bool {
	return b.direction == .Right_To_Left || b.direction == .Top_To_Bottom
}

// The track's length along its axis and its node's resolved rect.
@(private = "file")
_track :: proc(b: ^Scrollbar) -> (node: engine.Node_Rect, length: f32, ok: bool) {
	canvas := engine.canvas_of(b.owner)
	if canvas == {} do return
	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	for n in nodes do if n.tH == b.owner {
		return n, n.rect.size.y if _vertical(b) else n.rect.size.x, true
	}
	return
}

// The handle's share of the track as drawn: its size, not under min_handle.
@(private = "file")
_handle_share :: proc(b: ^Scrollbar, length: f32) -> f32 {
	if length <= 0 do return 1
	return clamp(max(b.size, b.min_handle / length), 0, 1)
}

// Places the handle by its anchors: from the value and the size.
@(private = "file")
_scrollbar_place :: proc(b: ^Scrollbar) {
	_, rt := engine.transform_get_comp(engine.Transform_Handle(b.handle.handle), engine.RectTransform)
	if rt == nil do return
	_, length, ok := _track(b)
	if !ok do return
	share := _handle_share(b, length)
	v := 1 - b.value if _reversed(b) else b.value
	lo := v * (1 - share)
	hi := lo + share
	if _vertical(b) {
		rt.anchor_min, rt.anchor_max = {0, lo}, {1, hi}
	} else {
		rt.anchor_min, rt.anchor_max = {lo, 0}, {hi, 1}
	}
	rt.size_delta = {0, 0}
	rt.anchored_position = {0, 0, rt.anchored_position.z}
}

// The Scrollbar takes the press on its node or its handle and keeps the drag.
// A press on the handle holds it where it was grabbed. A press on the track
// brings the handle's middle there.
@(comp_on_pointer={component=Scrollbar})
comp_on_pointer_Scrollbar :: proc(b: ^Scrollbar, ev: ^pointer.Pointer_Event) {
	#partial switch ev.kind {
	case .Down:
		if ev.button != .Left do return
		ev.used = true
		ev.own_drag = true
		b.dragging = true
		handle_tH := engine.Transform_Handle(b.handle.handle)
		at, share, ok := _pointer_along(b, ev)
		if !ok do return
		v := 1 - b.value if _reversed(b) else b.value
		lo := v * (1 - share)
		if handle_tH != {} && engine.transform_is_under(ev.target, handle_tH) && share > 0 {
			b.grab = clamp((at - lo) / share, 0, 1)
		} else {
			b.grab = 0.5
			_scrollbar_drag_to(b, at, share)
		}
	case .Drag:
		at, share, ok := _pointer_along(b, ev)
		if ok do _scrollbar_drag_to(b, at, share)
	case .Up, .Cancel, .Drag_End:
		b.dragging = false
	}
}

// Where the pointer is along the track, 0 to 1 from its start, and the
// handle's share of it.
@(private = "file")
_pointer_along :: proc(b: ^Scrollbar, ev: ^pointer.Pointer_Event) -> (at, share: f32, ok: bool) {
	node, length, has := _track(b)
	if !has || length <= 0 do return
	p := pointer.canvas_position(ev) or_return
	local := (linalg.inverse(node.xform) * [4]f32{p.x, p.y, 0, 1}).xy
	along := (local.y - node.rect.pos.y) if _vertical(b) else (local.x - node.rect.pos.x)
	return along / length, _handle_share(b, length), true
}

@(private = "file")
_scrollbar_drag_to :: proc(b: ^Scrollbar, at, share: f32) {
	free := 1 - share
	v := f32(0)
	if free > 0.0001 do v = clamp((at - b.grab * share) / free, 0, 1)
	value := 1 - v if _reversed(b) else v
	if value != b.value do b.changed = true
	b.value = value
	_scrollbar_place(b)
}
