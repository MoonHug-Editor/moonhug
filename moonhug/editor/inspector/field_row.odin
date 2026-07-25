package inspector

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"

// Unity's inspector row: the label occupies a fixed-width left column and the
// value fills the rest of the row. Ported from UnityCsReference —
// EditorGUIUtility.labelWidth and EditorGUI.PrefixLabel:
//
//     labelWidth = max(ceil(contextWidth * 0.45) - 40, 120)
//     label rect = [row.x + indent,        labelWidth - indent]
//     field rect = [row.x + labelWidth + 2, row.width - labelWidth - 2]
//
// Two properties of that formula do the real work, and both are easy to lose in
// a reimplementation:
//   - labelWidth reads the PANEL width, not the row width, so it is one value
//     shared by every row.
//   - the field boundary ignores indent. Indent is subtracted from the LABEL
//     instead. So nested foldout rows keep their value columns on the same x
//     however deep the nesting goes, which is what makes an inspector read as a
//     column rather than a staircase.
//
// imgui's own convention is the opposite — it draws the label AFTER the widget
// — so every labeled row in this package goes through field_row and hands the
// widget a display-suppressed label.

LABEL_WIDTH_RATIO :: f32(0.45)
LABEL_WIDTH_MARGIN :: f32(40)
MIN_LABEL_WIDTH :: f32(120)
PREFIX_PADDING_RIGHT :: f32(2)
// Unity's EditorGUIUtility.fieldWidth. A layout floor, not the drawn width: the
// value normally takes all the room left over, and this only matters once the
// panel is too narrow to give it that.
MIN_FIELD_WIDTH :: f32(50)

// Width of the label column for the panel the cursor is in. Every row in that
// panel gets the same answer, which is the point.
field_label_width :: proc() -> f32 {
	left, right := _panel_content_bounds()
	return max(math.ceil((right - left) * LABEL_WIDTH_RATIO) - LABEL_WIDTH_MARGIN, MIN_LABEL_WIDTH)
}

// Panel content edges, window-local, both independent of the current indent.
// GetCursorStartPos is the panel's content origin. Indent moves the cursor right
// and shrinks the available region by the same amount, so cursor + avail is the
// content right edge at any nesting depth.
//
// Odin-local note: these are procs, not struct reads. The binding's internal
// struct layouts do not match the compiled library (see drag_left.odin), so
// window and context fields are off limits here.
@(private = "file")
_panel_content_bounds :: proc() -> (left: f32, right: f32) {
	left = im.GetCursorStartPos().x
	right = im.GetCursorPosX() + im.GetContentRegionAvail().x
	return
}

// Draws `label` in the label column, then leaves the cursor at the value column
// with the next item's width set to the rest of the row. Returns the label to
// hand the widget: display-suppressed when this drew it.
//
// A label with nothing visible in it (empty, or pure "##id") takes Unity's
// PrefixLabel early out — no column, the value owns the whole row, and the
// caller's own width choice stands. Array elements rely on that.
//
// Widgets that size themselves explicitly rather than from the item width can
// read GetContentRegionAvail().x afterwards, which is exactly the value column.
field_row :: proc(label: cstring) -> cstring {
	if im.CalcTextSize(label, nil, true).x <= 0 do return label

	// Clip the label to its column so a long name truncates instead of running
	// under the value, matching the width Unity gives the label rect.
	p := im.GetCursorScreenPos()
	label_w := max(_field_column_x() - PREFIX_PADDING_RIGHT - im.GetCursorPosX(), 0)
	im.PushClipRect(p, im.Vec2{p.x + label_w, p.y + im.GetFrameHeight()}, true)
	im.AlignTextToFramePadding()
	im.TextEx(label, im.FindRenderedTextEnd(label), {})
	im.PopClipRect()

	return field_row_value(label)
}

// The value half of a row, for labels that are not plain text and so have to be
// drawn by the caller — a foldout arrow, for instance. Call it with the cursor
// still on the label's line.
field_row_value :: proc(label: cstring) -> cstring {
	_, right := _panel_content_bounds()
	field_x := _field_column_x()

	// SetCursorPosX is absolute window-local, so unlike SameLine(offset) it is
	// not shifted by an enclosing group or column. Rows here are wrapped in a
	// group by the caller, so that distinction matters.
	im.SameLine(0, 0)
	im.SetCursorPosX(field_x)
	im.SetNextItemWidth(max(right - field_x, MIN_FIELD_WIDTH))
	return fmt.ctprintf("##%s", label)
}

// Window-local x where the value column starts. Fixed for the panel, but never
// behind the cursor: past ~8 indent levels the label column is fully consumed
// and Unity would start drawing the field over the label. Pinning it to the
// cursor degrades to a zero-width label instead.
@(private = "file")
_field_column_x :: proc() -> f32 {
	left, _ := _panel_content_bounds()
	return max(left + field_label_width() + PREFIX_PADDING_RIGHT, im.GetCursorPosX())
}
