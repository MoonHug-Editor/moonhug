package inspector

// Property drawer for engine.Curve — a piecewise-linear curve editor
// (Unity's curve field, linear segments). The row shows a plot preview,
// clicking it opens the editor popup: drag keys, double-click to add,
// right-click a key to delete. Applies to ANY component field of type
// engine.Curve.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "../../engine"

@(private = "file") _curve_sel: int = -1
@(private = "file") _curve_dragging: bool

// Plot value range: keys padded, always containing 0..1 so flat curves read.
@(private = "file")
_curve_range :: proc(c: ^engine.Curve) -> (lo, hi: f32) {
	lo, hi = 0, 1
	for k in c.keys {
		lo = min(lo, k.value)
		hi = max(hi, k.value)
	}
	pad := (hi - lo) * 0.1
	return lo - pad, hi + pad
}

// Package-visible: the MinMax_Curve drawer reuses the plot and the editor.
_curve_plot :: proc(c: ^engine.Curve, p0, p1: im.Vec2) {
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, p0, p1, im.GetColorU32(.FrameBg), 2)
	lo, hi := _curve_range(c)
	span := max(hi - lo, 1e-4)
	col := im.GetColorU32ImVec4(im.Vec4{0.55, 0.85, 0.45, 1})
	STEPS :: 48
	prev: im.Vec2
	for i in 0 ..= STEPS {
		t := f32(i) / STEPS
		v := engine.curve_eval(c, t)
		pt := im.Vec2{
			p0.x + (p1.x - p0.x) * t,
			p1.y - (p1.y - p0.y) * clamp((v - lo) / span, 0, 1),
		}
		if i > 0 do im.DrawList_AddLine(dl, prev, pt, col, 1)
		prev = pt
	}
}

@(property_drawer={type = engine.Curve, priority = 0})
draw_curve_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	c := cast(^engine.Curve)ptr
	field_row(label)

	w := im.GetContentRegionAvail().x
	h := im.GetFrameHeight()
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x + w, p0.y + h}
	popup_id := fmt.ctprintf("curve_edit##%s", label)
	if im.InvisibleButton(fmt.ctprintf("##curve_%s", label), im.Vec2{w, h}) {
		_curve_sel = -1
		_curve_dragging = false
		im.OpenPopup(popup_id)
	}
	_curve_plot(c, p0, p1)

	if im.BeginPopup(popup_id) {
		_curve_editor(c)
		im.EndPopup()
	}
}

_curve_editor :: proc(c: ^engine.Curve) {
	CW :: f32(340)
	CH :: f32(160)
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x + CW, p0.y + CH}
	im.InvisibleButton("##curve_canvas", im.Vec2{CW, CH})
	_curve_plot(c, p0, p1)

	lo, hi := _curve_range(c)
	span := max(hi - lo, 1e-4)
	to_screen :: proc(t, v, lo, span: f32, p0, p1: im.Vec2) -> im.Vec2 {
		return im.Vec2{p0.x + (p1.x - p0.x) * t, p1.y - (p1.y - p0.y) * clamp((v - lo) / span, 0, 1)}
	}

	dl := im.GetWindowDrawList()
	mouse := im.GetMousePos()
	hover_key := -1
	for k, i in c.keys {
		sp := to_screen(k.t, k.value, lo, span, p0, p1)
		if abs(mouse.x - sp.x) < 7 && abs(mouse.y - sp.y) < 7 do hover_key = i
		col := i == _curve_sel ? im.GetColorU32ImVec4(im.Vec4{1, 0.85, 0.2, 1}) : im.GetColorU32(.Text)
		im.DrawList_AddCircleFilled(dl, sp, 4, col)
	}

	changed := false
	hovered := im.IsItemHovered({})
	if im.IsItemActivated() {
		_curve_sel = hover_key
		_curve_dragging = hover_key >= 0
	}
	if _curve_dragging && _curve_sel >= 0 && im.IsItemActive() {
		k := &c.keys[_curve_sel]
		t := clamp((mouse.x - p0.x) / (p1.x - p0.x), 0, 1)
		// Stay sorted: a key never crosses its neighbors.
		if _curve_sel > 0 do t = max(t, c.keys[_curve_sel - 1].t + 0.001)
		if _curve_sel < len(c.keys) - 1 do t = min(t, c.keys[_curve_sel + 1].t - 0.001)
		k.t = t
		k.value = lo + (1 - clamp((mouse.y - p0.y) / (p1.y - p0.y), 0, 1)) * span
		changed = true
	}
	if im.IsItemDeactivated() do _curve_dragging = false

	// Double-click empty canvas: a key at the mouse, kept sorted.
	if hovered && hover_key < 0 && im.IsMouseDoubleClicked(.Left) {
		t := clamp((mouse.x - p0.x) / (p1.x - p0.x), 0, 1)
		v := lo + (1 - clamp((mouse.y - p0.y) / (p1.y - p0.y), 0, 1)) * span
		at := len(c.keys)
		for k, i in c.keys do if k.t > t { at = i; break }
		inject_at(&c.keys, at, engine.Curve_Key{t = t, value = v})
		_curve_sel = at
		changed = true
	}
	if hovered && hover_key >= 0 && im.IsMouseClicked(.Right) {
		ordered_remove(&c.keys, hover_key)
		_curve_sel = -1
		changed = true
	}

	if _curve_sel >= 0 && _curve_sel < len(c.keys) {
		k := &c.keys[_curve_sel]
		im.SetNextItemWidth(120)
		if im.DragFloat("t##curve_key", &k.t, 0.005, 0, 1) {
			if _curve_sel > 0 do k.t = max(k.t, c.keys[_curve_sel - 1].t + 0.001)
			if _curve_sel < len(c.keys) - 1 do k.t = min(k.t, c.keys[_curve_sel + 1].t - 0.001)
			changed = true
		}
		im.SameLine()
		im.SetNextItemWidth(120)
		if im.DragFloat("value##curve_key", &k.value, 0.01) do changed = true
	} else {
		im.TextDisabled("double-click adds a key, right-click deletes")
	}
	if im.Button("Clear (module off)") {
		clear(&c.keys)
		_curve_sel = -1
		changed = true
	}

	if changed do mark_inspector_changed()
}
