package inspector

// Property drawer for engine.MinMax_Curve — Unity's MinMaxCurve field: a
// small mode button (▾ popup: Constant / Random Between Two Constants /
// Curve / Random Between Two Curves) followed by the mode's widgets — drags
// for constants, clickable curve plots (the shared curve editor popup) for
// curves. Applies to ANY component field of type engine.MinMax_Curve.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "../../engine"

@(private = "file")
_mm_mode_names := [engine.MinMax_Mode]cstring{
	.Constant             = "Constant",
	.Random_Two_Constants = "Random Between Two Constants",
	.Curve                = "Curve",
	.Random_Two_Curves    = "Random Between Two Curves",
}

// One clickable curve plot with its own editor popup.
@(private = "file")
_mm_curve_cell :: proc(c: ^engine.Curve, id: cstring, w: f32) {
	h := im.GetFrameHeight()
	p0 := im.GetCursorScreenPos()
	popup_id := fmt.ctprintf("mm_curve_edit%s", id)
	if im.InvisibleButton(id, im.Vec2{w, h}) {
		im.OpenPopup(popup_id)
	}
	_curve_plot(c, p0, im.Vec2{p0.x + w, p0.y + h})
	if im.BeginPopup(popup_id) {
		_curve_editor(c)
		im.EndPopup()
	}
}

@(property_drawer={type = engine.MinMax_Curve, priority = 0})
draw_minmax_curve_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	mm := cast(^engine.MinMax_Curve)ptr
	field_row(label)

	// Mode selector, Unity's little dropdown at the field's edge.
	if im.SmallButton(fmt.ctprintf("\xe2\x96\xbe##mm_mode_%s", label)) {
		im.OpenPopup("mm_mode")
	}
	if im.BeginPopup("mm_mode") {
		for name, mode in _mm_mode_names {
			if im.Selectable(name, mm.mode == mode) {
				mm.mode = mode
				mark_inspector_changed()
			}
		}
		im.EndPopup()
	}
	im.SameLine()

	avail := im.GetContentRegionAvail().x
	switch mm.mode {
	case .Constant:
		im.SetNextItemWidth(avail)
		if drag_float(fmt.ctprintf("##mm_v%s", label), &mm.value_min, 0.05) {
			mark_inspector_changed()
		}
	case .Random_Two_Constants:
		half := (avail - 4) * 0.5
		im.SetNextItemWidth(half)
		if drag_float(fmt.ctprintf("##mm_lo%s", label), &mm.value_min, 0.05) {
			mark_inspector_changed()
		}
		im.SameLine(0, 4)
		im.SetNextItemWidth(half)
		if drag_float(fmt.ctprintf("##mm_hi%s", label), &mm.value_max, 0.05) {
			mark_inspector_changed()
		}
	case .Curve:
		_mm_curve_cell(&mm.curve_min, "##mm_c", avail)
	case .Random_Two_Curves:
		half := (avail - 4) * 0.5
		_mm_curve_cell(&mm.curve_min, "##mm_clo", half)
		im.SameLine(0, 4)
		_mm_curve_cell(&mm.curve_max, "##mm_chi", half)
	}
}
