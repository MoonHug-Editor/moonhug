package mhgui

// mhgui — the UI package (docs/Gui.md): RectTransform lays a node out
// inside its parent's rect, Canvas roots a UI tree on the game viewport,
// CanvasRenderer draws a node's rect.

import "moonhug:engine"

// A rectangle in canvas pixels: bottom-left origin, y up, the same
// orientation as NDC.
Rect :: struct {
	pos:  [2]f32, // bottom-left corner
	size: [2]f32,
}

// The mhgui layout component. The node's rect derives from the PARENT rect: the
// anchors pick a sub-rect of it, size_delta grows that sub-rect, and the
// pivot lands on the anchor reference point plus anchored_position. The
// node's Transform position, rotation and scale take no part.
@(component={menu="UI/Rect Transform"})
@(typ_guid={guid = "36e133bb-7979-48ba-8b1b-57385558f37d"})
RectTransform :: struct {
	using base:        engine.CompData `inspect:"-"`,
	anchor_min:        [2]f32, // parent-relative 0..1, bottom-left anchor
	anchor_max:        [2]f32, // parent-relative 0..1, top-right anchor
	pivot:             [2]f32, // 0..1 inside the node's own rect
	anchored_position: [2]f32, // pivot offset from the anchor reference point, px
	size_delta:        [2]f32, // size added to the anchor span, px
}

reset_RectTransform :: proc(rt: ^RectTransform) {
	rt.anchor_min = {0.5, 0.5}
	rt.anchor_max = {0.5, 0.5}
	rt.pivot = {0.5, 0.5}
	rt.size_delta = {100, 100}
}

// The rect math. With both anchors equal the node has a fixed size
// (size_delta) at a point; with anchors apart it stretches with the parent
// and size_delta is the margin (negative shrinks).
rect_resolve :: proc(parent: Rect, rt: ^RectTransform) -> Rect {
	lo := parent.pos + parent.size * rt.anchor_min
	hi := parent.pos + parent.size * rt.anchor_max
	size := (hi - lo) + rt.size_delta
	pivot_pos := lo + (hi - lo) * rt.pivot + rt.anchored_position
	return Rect{pos = pivot_pos - size * rt.pivot, size = size}
}

// --- Rect tool edits (the scene-view gizmo, tests) --------------------------------

// Moves the rect by `delta` canvas pixels.
rect_drag_move :: proc(rt: ^RectTransform, delta: [2]f32) {
	rt.anchored_position += delta
}

// Drags edges by `delta` canvas pixels. `sides` picks the moving edge per
// axis: -1 the low edge (left, bottom), +1 the high edge (right, top), 0
// none. The opposite edge stays where it is, so the pivot-relative position
// shifts by the pivot's share of the change.
rect_drag_edges :: proc(rt: ^RectTransform, sides: [2]i8, delta: [2]f32) {
	for axis in 0 ..< 2 {
		switch sides[axis] {
		case 1:
			rt.size_delta[axis] += delta[axis]
			rt.anchored_position[axis] += delta[axis] * rt.pivot[axis]
		case -1:
			rt.size_delta[axis] -= delta[axis]
			rt.anchored_position[axis] += delta[axis] * (1 - rt.pivot[axis])
		}
	}
}
