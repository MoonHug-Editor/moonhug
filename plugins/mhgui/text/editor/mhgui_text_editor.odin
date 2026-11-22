package mhgui_text_editor

// Editor half of mhgui's text integration: the GameObject, UI menu items
// that build an Input Field and a Dropdown with the nodes they need.

import "core:strings"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"
import mhgui "moonhug:packages/mhgui"
import mhgui_text "moonhug:packages/mhgui/text"
import text "moonhug:packages/text"

@(private = "file") _NONE :: engine.Transform_Handle{}

// Adds `key` to `tH` as a recorded step. `init` fills the new component
// before the step is recorded, so redo rebuilds it with those values.
@(private = "file")
_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey, init: proc(ptr: rawptr) = nil) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	if _, idx := engine.transform_find_comp(t, key); idx >= 0 do return
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return
	if init != nil do init(ptr)
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)
}

// The node to build under: the selection when it sits in a canvas, else a
// new canvas.
@(private = "file")
_parent :: proc() -> engine.Transform_Handle {
	parent := engine.inspector_active_selection()
	if engine.canvas_of(parent) != _NONE do return parent
	scene := engine.sm_scene_get_active()
	if scene == nil do return _NONE
	canvas := undo.record_create_child("Canvas", engine.Transform_Handle(scene.root.handle))
	if canvas != _NONE {
		_add_comp(canvas, .Canvas)
		_add_comp(canvas, .GraphicRaycaster)
	}
	return canvas
}

// A reference to another node of the scene, as a component saves one.
@(private = "file")
_ref_to :: proc(tH: engine.Transform_Handle) -> engine.Ref_Local {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t == nil do return {}
	lid := t.local_id
	if lid == 0 && t.scene != nil do lid = engine.sm_local_id_get_or_mint(t.scene, engine.Handle(tH))
	return {local_id = lid, handle = engine.Handle(tH)}
}

// What the next component's init proc reads: procs here take no closure.
@(private = "file")
_next: struct {
	rect:  engine.RectTransform,
	str:   string,
	color: [4]f32,
	size:  f32,
	a, b:  engine.Transform_Handle,
}

// A node with a RectTransform: stretched over its parent with `inset` taken
// off (left, bottom, right, top), or `size` at `pos` from the parent's
// centre when `stretch` is off.
@(private = "file")
_rect_node :: proc(name: string, parent: engine.Transform_Handle, stretch: bool, pos: [2]f32 = {}, size: [2]f32 = {}, inset: [4]f32 = {}, active := true, pivot := [2]f32{0.5, 0.5}) -> engine.Transform_Handle {
	tH: engine.Transform_Handle
	if active {
		tH = undo.record_create_child(name, parent)
	} else {
		// Inactive before the record, so it is part of the create.
		tH = engine.transform_new(name, parent)
		if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)); t != nil do t.is_active = false
		undo.record_create(tH, parent)
	}
	if tH == _NONE do return _NONE
	engine.type_reset_RectTransform(&_next.rect)
	_next.rect.pivot = pivot
	if stretch {
		_next.rect.anchor_min, _next.rect.anchor_max = {0, 0}, {1, 1}
		_next.rect.anchored_position = {(inset[0] - inset[2]) * 0.5, (inset[1] - inset[3]) * 0.5, 0}
		_next.rect.size_delta = {-(inset[0] + inset[2]), -(inset[1] + inset[3])}
	} else {
		_next.rect.anchored_position = {pos.x, pos.y, 0}
		_next.rect.size_delta = size
	}
	_add_comp(tH, .RectTransform, proc(ptr: rawptr) {
		rt := cast(^engine.RectTransform)ptr
		rt.anchor_min, rt.anchor_max = _next.rect.anchor_min, _next.rect.anchor_max
		rt.anchored_position = _next.rect.anchored_position
		rt.size_delta = _next.rect.size_delta
		rt.pivot = _next.rect.pivot
	})
	return tH
}

// A Text on `tH`: one line, left and middle, that takes no pointer.
@(private = "file")
_text :: proc(tH: engine.Transform_Handle, str: string, color: [4]f32, size: f32 = 18) {
	_next.str, _next.color, _next.size = str, color, size
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Text, proc(ptr: rawptr) {
		tx := cast(^text.Text)ptr
		if _next.str != "" do tx.text = strings.clone(_next.str) // the component owns its string
		tx.font = engine.PPtr{guid = text.default_font_guid()}
		tx.material = engine.PPtr{guid = text.default_material_guid()}
		tx.font_size = _next.size
		tx.color = _next.color
		tx.wrap = false
		tx.horizontal_alignment = .Left
		tx.vertical_alignment = .Middle
		tx.raycast_target = false
	})
}

// A UiShape on `tH`: a rounded card.
@(private = "file")
_card :: proc(tH: engine.Transform_Handle, color: [4]f32) {
	_next.color = color
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .UiShape, proc(ptr: rawptr) {
		s := cast(^mhgui.UiShape)ptr
		s.color = _next.color
		s.corner_radius = {8, 8, 8, 8}
	})
}

// An Input Field: a card, a masked Text Area with the caret's graphic, and
// in it the hint and the Text that shows what is typed.
@(menu_item={path="GameObject/UI/Input Field", order=58, help="Creates a text field: a card with a Text the user types into"})
ui_menu_input_field :: proc() {
	g := undo.group_begin("Create Input Field")
	defer undo.group_end(&g)
	parent := _parent()
	if parent == _NONE do return
	field := _rect_node("Input Field", parent, false, size = {240, 40})
	if field == _NONE do return
	_card(field, {0.16, 0.18, 0.26, 1})
	area := _rect_node("Text Area", field, true, inset = {12, 6, 12, 6})
	_add_comp(area, .CanvasRenderer)
	_add_comp(area, .UiMask)
	_add_comp(area, .InputCaret)
	hint := _rect_node("Placeholder", area, true)
	_text(hint, "Enter text...", {0.6, 0.63, 0.72, 0.8})
	shown := _rect_node("Text", area, true)
	_text(shown, "", {1, 1, 1, 1})
	_next.a, _next.b = shown, hint
	_add_comp(field, .InputField, proc(ptr: rawptr) {
		f := cast(^mhgui_text.InputField)ptr
		f.text_component = _ref_to(_next.a)
		f.placeholder = _ref_to(_next.b)
	})
	undo.group_commit(&g)
	engine.inspector_request_select(field)
}

// A Dropdown: a card with the chosen option's Label, and the Template of
// its list, inactive: a card that stacks its rows, with one Item.
@(menu_item={path="GameObject/UI/Dropdown", order=59, help="Creates a dropdown: a control that opens a list of options to pick one"})
ui_menu_dropdown :: proc() {
	g := undo.group_begin("Create Dropdown")
	defer undo.group_end(&g)
	parent := _parent()
	if parent == _NONE do return
	node := _rect_node("Dropdown", parent, false, size = {200, 40})
	if node == _NONE do return
	_card(node, {0.16, 0.18, 0.26, 1})
	label := _rect_node("Label", node, true, inset = {12, 0, 34, 0})
	_text(label, "Option A", {1, 1, 1, 1})
	arrow := _rect_node("Arrow", node, false, pos = {82, 0}, size = {16, 20})
	_text(arrow, "v", {0.7, 0.74, 0.85, 1}, 16)

	// The list hangs under the control and grows with its rows.
	template := _rect_node("Template", node, false, pos = {0, -24}, size = {200, 40}, active = false, pivot = {0.5, 1})
	_card(template, {0.20, 0.22, 0.31, 1})
	_add_comp(template, .LayoutGroup, proc(ptr: rawptr) {
		l := cast(^mhgui.LayoutGroup)ptr
		l.direction = .Vertical
		l.padding = {left = 4, right = 4, top = 4, bottom = 4}
		l.spacing = {2, 2}
		l.expand_width = true
	})
	_add_comp(template, .ContentSizeFitter, proc(ptr: rawptr) {
		(cast(^mhgui.ContentSizeFitter)ptr).vertical_fit = .Preferred_Size
	})
	row := _rect_node("Item", template, false, size = {192, 32})
	_card(row, {0.30, 0.34, 0.48, 1})
	mark := _rect_node("Checkmark", row, false, pos = {-82, 0}, size = {8, 8})
	_next.color = {0.4, 0.75, 1, 1}
	_add_comp(mark, .CanvasRenderer)
	_add_comp(mark, .UiShape, proc(ptr: rawptr) {
		s := cast(^mhgui.UiShape)ptr
		s.color = _next.color
		s.corner_radius = {4, 4, 4, 4}
		s.raycast_target = false
	})
	row_label := _rect_node("Item Label", row, true, inset = {24, 0, 8, 0})
	_text(row_label, "Option A", {1, 1, 1, 1}, 16)
	_next.a, _next.b = row_label, mark
	_add_comp(row, .DropdownItem, proc(ptr: rawptr) {
		item := cast(^mhgui_text.DropdownItem)ptr
		item.label = _ref_to(_next.a)
		item.checkmark = _ref_to(_next.b)
		// The row is the card's colour until the pointer or the keys are on it.
		item.colors.normal = {1, 1, 1, 0}
		item.colors.highlighted = {1, 1, 1, 1}
		item.colors.selected = {1, 1, 1, 1}
		item.colors.pressed = {0.8, 0.8, 0.8, 1}
	})
	_next.a, _next.b = label, template
	_add_comp(node, .Dropdown, proc(ptr: rawptr) {
		d := cast(^mhgui_text.Dropdown)ptr
		d.caption = _ref_to(_next.a)
		d.template = _ref_to(_next.b)
		for o in ([]string{"Option A", "Option B", "Option C"}) do append(&d.options, strings.clone(o))
	})
	undo.group_commit(&g)
	engine.inspector_request_select(node)
}
