package text_editor

// Editor half of the text plugin: GameObject > UI > Text, and scene-view
// picking of text rects. Independent of packages/mhgui: it builds the same
// node shape (RectTransform + CanvasRenderer + Text) with the engine's canvas
// vocabulary alone.

import "moonhug:engine"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import text "moonhug:packages/text"
import "core:encoding/uuid"
import "core:strings"

@(private = "file") _NONE :: engine.Transform_Handle{}

// The font that ships with the package (assets/Roboto-Medium.ttf, Apache-2.0).
DEFAULT_FONT_GUID :: "22073e17-4d3a-44ab-a230-03bea296e8b7"

@(private = "file")
_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return nil
	if _, idx := engine.transform_find_comp(t, key); idx >= 0 do return nil
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return nil
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
// new canvas. 160x30, the package font, "New Text".
@(menu_item={path="GameObject/UI/Text", order=52})
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
	if rt := cast(^engine.RectTransform)_add_comp(tH, .RectTransform); rt != nil {
		rt.size_delta = {160, 30}
	}
	_add_comp(tH, .CanvasRenderer)
	if tx := cast(^text.Text)_add_comp(tH, .Text); tx != nil {
		tx.text = strings.clone("New Text") // the component owns its string (cleanup_Text)
		if guid, err := uuid.read(DEFAULT_FONT_GUID); err == nil do tx.font = engine.Asset_GUID(guid)
	}
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// Text rects are clickable in the scene view like image rects.
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
