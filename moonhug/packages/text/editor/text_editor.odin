package text_editor

// Editor half of text: the font importer (editor-side, like audio's), the
// GameObject > UI > Text menu, and scene-view picking of text rects.

import "core:encoding/uuid"
import "core:strings"
import "moonhug:engine"
import "moonhug:engine_editor/asset_pipeline"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import text "moonhug:packages/text"

@(private = "file") _NONE :: engine.Transform_Handle{}

// The SDF material that ships with the package (assets/materials/TextSDF.mat).
TEXT_SDF_MATERIAL_GUID :: "57209af0-8443-465e-ab7b-cd1deec09ec6"

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
		if m, err := uuid.read(TEXT_SDF_MATERIAL_GUID); err == nil do tx.material = engine.Asset_GUID(m)
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
