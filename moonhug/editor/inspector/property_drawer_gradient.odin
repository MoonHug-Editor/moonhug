package inspector

// Property drawer for engine.Gradient — Unity's gradient field with linear
// blending. The row shows the gradient bar, clicking it opens the editor
// popup: markers under the bar select/drag keys, double-click the bar adds
// one, the selected key edits color and t. Applies to ANY component field of
// type engine.Gradient.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "../../engine"

@(private = "file") _grad_sel: int = -1
@(private = "file") _grad_dragging: bool

@(private = "file")
_grad_col32 :: proc(c: [4]f32) -> u32 {
	return im.GetColorU32ImVec4(im.Vec4{c.r, c.g, c.b, c.a})
}

// The bar: one horizontal multi-color fill per segment, flat ends.
@(private = "file")
_grad_bar :: proc(g: ^engine.Gradient, p0, p1: im.Vec2) {
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, p0, p1, im.GetColorU32(.FrameBg), 2)
	x_at :: proc(t: f32, p0, p1: im.Vec2) -> f32 { return p0.x + (p1.x - p0.x) * clamp(t, 0, 1) }

	if len(g.keys) == 0 {
		im.DrawList_AddRectFilled(dl, p0, p1, _grad_col32({1, 1, 1, 1}), 2)
		return
	}
	first := g.keys[0]
	last := g.keys[len(g.keys) - 1]
	im.DrawList_AddRectFilled(dl, p0, im.Vec2{x_at(first.t, p0, p1), p1.y}, _grad_col32(first.color))
	for i in 1 ..< len(g.keys) {
		a, b := g.keys[i - 1], g.keys[i]
		im.DrawList_AddRectFilledMultiColor(dl,
			im.Vec2{x_at(a.t, p0, p1), p0.y}, im.Vec2{x_at(b.t, p0, p1), p1.y},
			_grad_col32(a.color), _grad_col32(b.color), _grad_col32(b.color), _grad_col32(a.color))
	}
	im.DrawList_AddRectFilled(dl, im.Vec2{x_at(last.t, p0, p1), p0.y}, p1, _grad_col32(last.color))
}

@(property_drawer={type = engine.Gradient, priority = 0})
draw_gradient_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	g := cast(^engine.Gradient)ptr
	field_row(label)

	w := im.GetContentRegionAvail().x
	h := im.GetFrameHeight()
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x + w, p0.y + h}
	popup_id := fmt.ctprintf("gradient_edit##%s", label)
	if im.InvisibleButton(fmt.ctprintf("##gradient_%s", label), im.Vec2{w, h}) {
		_grad_sel = -1
		_grad_dragging = false
		im.OpenPopup(popup_id)
	}
	_grad_bar(g, p0, p1)

	if im.BeginPopup(popup_id) {
		_gradient_editor(g)
		im.EndPopup()
	}
}

@(private = "file")
_gradient_editor :: proc(g: ^engine.Gradient) {
	BW :: f32(320)
	BH :: f32(26)
	MARKER_H :: f32(12)
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x + BW, p0.y + BH}
	im.InvisibleButton("##gradient_bar", im.Vec2{BW, BH + MARKER_H})
	_grad_bar(g, p0, p1)

	dl := im.GetWindowDrawList()
	mouse := im.GetMousePos()
	hover_key := -1
	for k, i in g.keys {
		x := p0.x + BW * clamp(k.t, 0, 1)
		if abs(mouse.x - x) < 6 && mouse.y >= p0.y && mouse.y <= p1.y + MARKER_H do hover_key = i
		col := i == _grad_sel ? im.GetColorU32ImVec4(im.Vec4{1, 0.85, 0.2, 1}) : im.GetColorU32(.Text)
		im.DrawList_AddTriangleFilled(dl,
			im.Vec2{x, p1.y}, im.Vec2{x - 5, p1.y + MARKER_H}, im.Vec2{x + 5, p1.y + MARKER_H}, col)
	}

	changed := false
	hovered := im.IsItemHovered({})
	if im.IsItemActivated() {
		_grad_sel = hover_key
		_grad_dragging = hover_key >= 0
	}
	if _grad_dragging && _grad_sel >= 0 && im.IsItemActive() {
		k := &g.keys[_grad_sel]
		t := clamp((mouse.x - p0.x) / BW, 0, 1)
		if _grad_sel > 0 do t = max(t, g.keys[_grad_sel - 1].t + 0.001)
		if _grad_sel < len(g.keys) - 1 do t = min(t, g.keys[_grad_sel + 1].t - 0.001)
		k.t = t
		changed = true
	}
	if im.IsItemDeactivated() do _grad_dragging = false

	// Double-click the bar: a key at the mouse with the gradient's color
	// there, kept sorted.
	if hovered && hover_key < 0 && im.IsMouseDoubleClicked(.Left) {
		t := clamp((mouse.x - p0.x) / BW, 0, 1)
		at := len(g.keys)
		for k, i in g.keys do if k.t > t { at = i; break }
		inject_at(&g.keys, at, engine.Gradient_Key{t = t, color = engine.gradient_eval(g, t)})
		_grad_sel = at
		changed = true
	}

	if _grad_sel >= 0 && _grad_sel < len(g.keys) {
		k := &g.keys[_grad_sel]
		if im.ColorEdit4("color##grad_key", &k.color, {.AlphaBar}) do changed = true
		im.SetNextItemWidth(120)
		if im.DragFloat("t##grad_key", &k.t, 0.005, 0, 1) {
			if _grad_sel > 0 do k.t = max(k.t, g.keys[_grad_sel - 1].t + 0.001)
			if _grad_sel < len(g.keys) - 1 do k.t = min(k.t, g.keys[_grad_sel + 1].t - 0.001)
			changed = true
		}
		im.SameLine()
		if im.Button("Delete Key") {
			ordered_remove(&g.keys, _grad_sel)
			_grad_sel = -1
			changed = true
		}
	} else {
		im.TextDisabled("double-click adds a key")
	}
	if im.Button("Clear (module off)") {
		clear(&g.keys)
		_grad_sel = -1
		changed = true
	}

	if changed do mark_inspector_changed()
}
