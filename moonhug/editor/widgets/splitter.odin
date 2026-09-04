package widgets

// Shared imgui widgets for editor views. Every window that splits into panes
// uses `splitter`, so the gap, the hit area and the highlight are the same
// everywhere.

import im "moonhug:external/odin-imgui"

// Gap between two panes.
SPLITTER_SIZE :: f32(4)

// The drag hit area reaches this far past the gap on both sides, into the
// panes (imgui's own window-edge grab padding), so a 4px gap is still easy
// to grab.
@(private = "file") _HOVER_EXTEND :: f32(4)

// Highlight only after the pointer rests on the gap this long, so passing
// over it does not flash (imgui's window-edge feedback timer).
@(private = "file") _HOVER_DELAY :: f32(0.04)

// A pane splitter that draws nothing at rest: the gap is the only mark. Under
// the pointer it highlights the way imgui's splitter between docked views
// does: a strip of style.DockingSeparatorSize centered in the gap, in
// ResizeGripHovered, ResizeGripActive while dragging, resize-arrow cursor.
// (imgui draws its dock splitters through SplitterBehavior with the
// Separator colors swapped for the ResizeGrip ones, DockNodeUpdate in
// imgui.cpp. The same swap here keeps both highlights identical in every
// theme.)
//
// Call it between the two panes. It takes SPLITTER_SIZE along the split axis
// and the full available extent across it. `vertical` is an upright strip
// between side-by-side panes (callers place it with SameLine(0, 0)). For
// stacked panes the strip pulls back over the ItemSpacing the pane above
// added and adds none after itself, so the gap is exactly SPLITTER_SIZE.
//
// `size1` and `size2` are the pane extents before and after the gap along
// the axis. Dragging moves extent between them, never below `min1` / `min2`.
// Returns true on a frame the drag changed them.
splitter :: proc(id: cstring, vertical: bool, size1, size2: ^f32, min1, min2: f32) -> bool {
	style := im.GetStyle()
	pos := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if !vertical {
		pos.y -= style.ItemSpacing.y
		im.SetCursorScreenPos(pos)
	}
	size := im.Vec2{SPLITTER_SIZE, avail.y} if vertical else im.Vec2{avail.x, SPLITTER_SIZE}
	im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{0, 0})
	im.Dummy(size)
	im.PopStyleVar()

	// The highlight strip, centered in the gap. The hit area grows back out
	// to the gap plus the padding.
	line := min(style.DockingSeparatorSize, SPLITTER_SIZE)
	inset := (SPLITTER_SIZE - line) * 0.5
	bb: im.Rect
	if vertical {
		bb = {pos + {inset, 0}, pos + {inset + line, size.y}}
	} else {
		bb = {pos + {0, inset}, pos + {size.x, inset + line}}
	}

	// WindowBg under the strip first, as the dock splitter does: the highlight
	// may be translucent, and without the same base it composites darker.
	im.PushStyleColorImVec4(.Separator, im.Vec4{}) // nothing at rest
	im.PushStyleColorImVec4(.SeparatorHovered, im.GetStyleColorVec4(.ResizeGripHovered)^)
	im.PushStyleColorImVec4(.SeparatorActive, im.GetStyleColorVec4(.ResizeGripActive)^)
	changed := im.SplitterBehavior(
		bb,
		im.GetID(id),
		.X if vertical else .Y,
		size1, size2, min1, min2,
		inset + _HOVER_EXTEND, _HOVER_DELAY,
		im.GetColorU32(.WindowBg),
	)
	im.PopStyleColor(3)
	return changed
}
