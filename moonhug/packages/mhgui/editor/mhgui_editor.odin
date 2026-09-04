package mhgui_editor

// Editor half of mhgui: the GameObject > UI menu, building UI nodes. Each
// menu action is one undo step.

import "moonhug:engine"
import "moonhug:editor/undo"
import mhgui "moonhug:packages/mhgui"

@(private = "file") _NONE :: engine.Transform_Handle{}

// Adds `key` to `tH` as a recorded step; no-op when the node has one already.
@(private = "file")
_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	if _, idx := engine.transform_find_comp(t, key); idx >= 0 do return
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)
}

// The canvas node the selection sits in (itself included), or _NONE.
@(private = "file")
_selected_canvas :: proc() -> engine.Transform_Handle {
	w := engine.ctx_world()
	tH := engine.inspector_active_selection()
	for tH != _NONE {
		if _, c := mhgui.get_comp(tH, mhgui.Canvas); c != nil do return tH
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return _NONE
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return _NONE
}

// A new Canvas node at the scene root.
@(private = "file")
_create_canvas :: proc() -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return _NONE
	tH := undo.record_create_child("Canvas", engine.Transform_Handle(scene.root.handle))
	if tH != _NONE do _add_comp(tH, .Canvas)
	return tH
}

@(menu_item={path="GameObject/UI/Canvas", order=50})
ui_menu_canvas :: proc() {
	g := undo.group_begin("Create Canvas")
	defer undo.group_end(&g)
	tH := _create_canvas()
	if tH == _NONE do return
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// An Image node: under the selection when that sits in a canvas, else under
// a new canvas.
@(menu_item={path="GameObject/UI/Image", order=51})
ui_menu_image :: proc() {
	g := undo.group_begin("Create Image")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if _selected_canvas() == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Image", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform)
	_add_comp(tH, .CanvasRenderer)
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}
