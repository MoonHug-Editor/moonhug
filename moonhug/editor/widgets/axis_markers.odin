package widgets

// Axis markers: the colored stripe on the left of each component field of a
// vector, x red, y green, z blue, w grey. The colors are the ones imgui's
// color editor marks its R, G, B and A fields with, so a vector row and a
// color row look alike. The stripe width is the style's ColorMarkerSize.
//
// Every editor of a 1 to 4 component vector marks its fields this way:
//   - the inspector's drag_float2/3/4 mark every component themselves
//     (inspector/drag_left.odin), so every vector row drawn through them is
//     marked
//   - an editor drawing one field per component calls axis_marker_next with
//     the component's index right before the field

import im "moonhug:external/odin-imgui"

// x, y, z, w, packed as imgui packs colors (R in the low byte).
AXIS_MARKER_COLORS :: [4]u32{
	0xFF1414F0, // x: 240, 20, 20
	0xFF14F014, // y: 20, 240, 20
	0xFFF01414, // z: 20, 20, 240
	0xFF8C8C8C, // w: 140, 140, 140
}

// Marks the next drag or slider field as component `axis` (0 x to 3 w). Call
// it right before the field, after any SameLine. Out of range does nothing.
axis_marker_next :: proc(axis: int) {
	if axis < 0 || axis >= 4 do return
	colors := AXIS_MARKER_COLORS
	im.SetNextItemColorMarker(colors[axis])
}
