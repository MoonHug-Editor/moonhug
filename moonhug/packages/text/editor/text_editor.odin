package text_editor

// Editor half of text: the font importer (editor-side, like audio's), the
// GameObject > UI > Text menu, the Text inspector's text area and style
// toggles, and scene-view picking of text rects.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:engine_editor/asset_pipeline"
import "moonhug:editor/handles"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import text "moonhug:packages/text"

@(private = "file") _NONE :: engine.Transform_Handle{}

_FONT_EXTS := []string{".ttf", ".otf"}

@(phase={key=ImportersInit, order=1, mode=Editor})
text_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	asset_pipeline.importer_register({
		name         = "font",
		version      = 2,
		extensions   = _FONT_EXTS,
		settings_tid = typeid_of(text.FontSettings),
		run          = text.font_import,
	})
}

// `init` fills the new component before the step is recorded, so redo
// rebuilds it with those values, not the reset defaults.
@(private = "file")
_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey, init: proc(ptr: rawptr) = nil) -> rawptr {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return nil
	if _, idx := engine.transform_find_comp(t, key); idx >= 0 do return nil
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return nil
	if init != nil do init(ptr)
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)
	return ptr
}

@(private = "file")
_create_canvas :: proc() -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return _NONE
	tH := undo.record_create_child("Canvas", engine.Transform_Handle(scene.root.handle))
	if tH != _NONE do _add_comp(tH, .Canvas)
	return tH
}

// A Text node: under the selection when that sits in a canvas, else under a
// new canvas. 200x50, the package's Roboto, the SDF material.
@(menu_item={path="GameObject/UI/Text", order=53})
ui_menu_text :: proc() {
	g := undo.group_begin("Create Text")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if engine.canvas_of(parent) == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Text", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform, proc(ptr: rawptr) {
		(cast(^engine.RectTransform)ptr).size_delta = {200, 50}
	})
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Text, proc(ptr: rawptr) {
		tx := cast(^text.Text)ptr
		tx.text = strings.clone("New Text") // the component owns its string (cleanup_Text)
		tx.font = text.default_font_guid()
		tx.material = text.default_material_guid()
	})
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

@(private = "file")
_pick_text :: proc(view: engine.Render_View, ray: engine.Ray) -> (engine.Transform_Handle, f32, bool) {
	if view.kind != .SceneView do return _NONE, 0, false
	w := engine.ctx_world()
	best_t := f32(1e30)
	best := _NONE
	found := false
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&it) {
		if !canvas.enabled || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		clear(&nodes)
		engine.canvas_resolve_rects(canvas.owner, engine.canvas_world_rect(canvas.owner), &nodes)
		for n in nodes {
			_, cr := engine.transform_get_comp(n.tH, engine.CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			_, tx := text.get_comp(n.tH, text.Text)
			if tx == nil || !tx.enabled do continue
			c := engine.rect_corners(n.rect, n.xform)
			if t, hit := engine.ray_hit_triangle(ray, c[0], c[1], c[2]); hit && t < best_t {
				best_t, best, found = t, n.tH, true
			}
			if t, hit := engine.ray_hit_triangle(ray, c[0], c[2], c[3]); hit && t < best_t {
				best_t, best, found = t, n.tH, true
			}
		}
	}
	return best, best_t, found
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
text_editor_install :: proc() {
	handles.pick_register(_pick_text)
}

// --- Inspector ---------------------------------------------------------------------

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
text_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(text.Text), _text_inspector)
}

// The text area and the style toggles first, then the generic rows. Both
// custom rows go through the inspector's row machinery, so undo sessions,
// multiedit peers and prefab overrides work like generic rows.
@(private = "file")
_text_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	tx := cast(^text.Text)ctx.ptr
	_text_row(tx, &tx.text, typeid_of(string), "Text", "text", _draw_text_area, nil)
	// Buttons have no edit gesture imgui reports, so a click stands in for a
	// whole gesture: began and finished on the same frame (_style_ws).
	_style_ws = {}
	_text_row(tx, &tx.font_style, typeid_of(text.Font_Style), "Font Style", "font_style", _draw_font_style, &_style_ws)
	inspector.draw(ctx)
}

@(private = "file")
_text_row :: proc(tx: ^text.Text, ptr: rawptr, tid: typeid, label: cstring, path: string, drawer: proc(ptr: rawptr, tid: typeid, label: cstring), ws: ^inspector.Widget_State) {
	im.PushIDStr(label, nil)
	offset := uintptr(ptr) - uintptr(tx)
	if ws != nil do inspector.field_edit_set_widget_state(ws)
	finished := inspector.field_edit_row(ptr, tid, offset, path, drawer, label)
	if ws != nil do inspector.field_edit_set_widget_state(nil)
	inspector.record_nested_override(ptr, tid, path, finished)
	im.PopID()
}

_TEXT_AREA_LINES :: 4

// A multi-line editor for the string. The component owns its string
// (cleanup_Text), so the old value is freed on every change.
@(private = "file")
_draw_text_area :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	str_ptr := cast(^string)ptr
	buf: [4096]u8
	// A mixed multi-selection starts empty; typing assigns to the whole selection.
	if !inspector.current_field_mixed do copy(buf[:len(buf) - 1], str_ptr^)
	id := inspector.field_row(label)
	h := im.GetTextLineHeight() * _TEXT_AREA_LINES + im.GetStyle().FramePadding.y * 2
	if im.InputTextMultiline(id, cstring(raw_data(buf[:])), len(buf), {0, h}, {}) {
		n := 0
		for n < len(buf) && buf[n] != 0 do n += 1
		if !inspector.current_field_mixed do delete(str_ptr^)
		str_ptr^ = strings.clone(string(buf[:n]))
		inspector.mark_inspector_changed()
	}
}

@(private = "file") _style_ws: inspector.Widget_State
@(private = "file") _style_button_w: f32

// Toggle buttons for the style flags. The case flags exclude each other.
@(private = "file")
_draw_font_style :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	style := cast(^text.Font_Style)ptr
	im.PushIDStr(inspector.field_row(label), nil)
	defer im.PopID()
	// Seven equal buttons across the value column.
	_style_button_w = (im.GetContentRegionAvail().x - im.GetStyle().ItemSpacing.x * 6) / 7
	changed := false
	changed |= _style_toggle("B", .Bold, style)
	changed |= _style_toggle("I", .Italic, style)
	changed |= _style_toggle("U", .Underline, style)
	changed |= _style_toggle("S", .Strikethrough, style)
	changed |= _style_toggle("ab", .Lowercase, style)
	changed |= _style_toggle("AB", .Uppercase, style)
	changed |= _style_toggle("SC", .Smallcaps, style)
	im.NewLine()
	if changed {
		_style_ws = {activated = true, deactivated_after_edit = true}
		inspector.mark_inspector_changed()
	}
}

@(private = "file")
_style_toggle :: proc(label: cstring, flag: text.Font_Style_Flag, style: ^text.Font_Style) -> bool {
	on := flag in style^
	if on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	clicked := im.Button(label, {_style_button_w, 0})
	if on do im.PopStyleColor()
	im.SameLine()
	if !clicked do return false
	if on {
		style^ -= {flag}
	} else {
		style^ += {flag}
		#partial switch flag {
		case .Lowercase, .Uppercase, .Smallcaps:
			style^ -= {.Lowercase, .Uppercase, .Smallcaps}
			style^ += {flag}
		}
	}
	return true
}
