package mhgui

import "moonhug:engine"

// Rect tool edits on a RectTransform (the scene-view gizmo in editor/, the
// tests here). Pure: they touch only the component's fields.

// Moves the rect by `delta` canvas units.
rect_drag_move :: proc(rt: ^engine.RectTransform, delta: [2]f32) {
	rt.anchored_position += delta
}

// Drags edges by `delta` canvas units. `sides` picks the moving edge per
// axis: -1 the low edge (left, bottom), +1 the high edge (right, top), 0
// none. The opposite edge stays where it is, so the pivot-relative position
// shifts by the pivot's share of the change.
rect_drag_edges :: proc(rt: ^engine.RectTransform, sides: [2]i8, delta: [2]f32) {
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
