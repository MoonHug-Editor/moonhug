package mhgui_editor

// Editor half of mhgui: the GameObject > UI menu, scene-view picking of UI
// rects, and the rect tool drawn on the selected RectTransform (built on
// editor/handles, docs/Handles.md). Each menu action and each drag is one
// undo step.

import "core:math/linalg"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:editor/handles"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import mhgui "moonhug:packages/mhgui"

@(private = "file") _NONE :: engine.Transform_Handle{}

// The canvas plane in the scene view.
@(private = "file") _PLANE_NORMAL :: [3]f32{0, 0, 1}

// Rect tool colors: the rect and its handles, the anchors, the pivot ring.
@(private = "file") _COLOR_RECT :: [4]f32{1, 1, 1, 0.9}
@(private = "file") _COLOR_ANCHOR :: [4]f32{1, 1, 1, 0.9}
@(private = "file") _COLOR_PIVOT :: [4]f32{0.3, 0.6, 1, 1}
@(private = "file") _COLOR_CANVAS :: [4]f32{1, 1, 1, 0.5}

// --- Menu ---------------------------------------------------------------------------

// Adds `key` to `tH` as a recorded step; no-op when the node has one already.
// `init` fills the new component before the step is recorded, so redo
// rebuilds it with those values, not the reset defaults.
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

// The canvas node `tH` sits in (itself included), or _NONE.
@(private = "file")
_canvas_of :: proc(start: engine.Transform_Handle) -> engine.Transform_Handle {
	w := engine.ctx_world()
	tH := start
	for tH != _NONE {
		if _, c := engine.transform_get_comp(tH, engine.Canvas); c != nil do return tH
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
	if tH != _NONE {
		_add_comp(tH, .Canvas)
		_add_comp(tH, .GraphicRaycaster)
	}
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

// An Image node (RectTransform + CanvasRenderer + Image): under the selection
// when that sits in a canvas, else under a new canvas.
@(menu_item={path="GameObject/UI/Image", order=51})
ui_menu_image :: proc() {
	g := undo.group_begin("Create Image")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if _canvas_of(parent) == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Image", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform)
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Image)
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// --- Scene-view picking -------------------------------------------------------------

// Every drawn UI rect, as the quads the scene view shows; nearest hit wins.
@(private = "file")
_pick_ui :: proc(view: engine.Render_View, ray: engine.Ray) -> (engine.Transform_Handle, f32, bool) {
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
			_, img := mhgui.get_comp(n.tH, mhgui.Image)
			if img == nil || !img.enabled do continue
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
mhgui_editor_install :: proc() {
	handles.pick_register(_pick_ui)
	inspector.add_component_wrapper(typeid_of(mhgui.Image), _image_inspector)
}

// A Button node: an Image as the target graphic plus the Button. Like the
// Image menu, under the selection when that sits in a canvas.
@(menu_item={path="GameObject/UI/Button", order=52})
ui_menu_button :: proc() {
	g := undo.group_begin("Create Button")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if _canvas_of(parent) == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Button", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform, proc(ptr: rawptr) {
		(cast(^engine.RectTransform)ptr).size_delta = {160, 30}
	})
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Image)
	_add_comp(tH, .Button)
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// --- Image inspector -------------------------------------------------------------------

// Default fields, then the Sprite row (the shared sprite picker; the field
// itself is inspect:"-") and Set Native Size, which sizes the node's
// RectTransform to the sprite's pixels as one undo step.
@(private = "file")
_image_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	img := cast(^mhgui.Image)ctx.ptr
	if inspector.sprite_ref_row("Sprite", &img.sprite) {
		inspector.mark_inspector_changed()
		inspector.record_nested_override(&img.sprite, typeid_of(engine.PPtr), "sprite", true)
	}
	owned, rt := engine.transform_get_comp(img.owner, engine.RectTransform)
	if rt == nil do return
	_, px, _, ok := mhgui.image_source(img)
	im.BeginDisabled(!ok)
	if im.Button("Set Native Size") {
		targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned.handle, &rt.size_delta, typeid_of([2]f32))}
		sess := undo.edit_session_begin(targets[:], "Set Native Size")
		rt.size_delta = {px.z, px.w}
		undo.edit_session_end(&sess)
		inspector.mark_inspector_changed()
	}
	im.EndDisabled()
}

// --- Canvas outline --------------------------------------------------------------------

// Every canvas shows its rect in the scene view, selected or not, so the UI
// space is visible next to the world.
@(on_draw_gizmos={component=Canvas})
canvas_gizmos :: proc(c: ^engine.Canvas) {
	if !engine.transform_active_in_hierarchy(c.owner) do return
	handles.rect(engine.canvas_world_corners(engine.canvas_world_rect(c.owner)), _COLOR_CANVAS)
}

// --- Rect tool -----------------------------------------------------------------------

// The drag in flight: the RectTransform as it was at grab, restored and
// re-edited from the total drag offset every frame so a drag is a pure
// function of where the pointer is now, and the undo session around it.
@(private = "file") _drag_start: engine.RectTransform
@(private = "file") _drag_edit: undo.Edit_Session

// Handle ids: the node's pool index scoped by a handle slot, never 0.
@(private = "file")
_handle_id :: proc(tH: engine.Transform_Handle, slot: u64) -> u64 {
	return (u64(tH.index) + 1) << 4 | slot
}

// One rect-tool handle: which edges it moves (-1 low, +1 high, 0 none per
// axis) and where it sits on the rect (0..1 per axis).
@(private = "file")
_Rect_Handle :: struct {
	sides: [2]i8,
	at:    [2]f32,
}

@(private = "file")
_RECT_HANDLES := [8]_Rect_Handle{
	{{-1, -1}, {0, 0}}, {{1, -1}, {1, 0}}, {{1, 1}, {1, 1}}, {{-1, 1}, {0, 1}}, // corners
	{{-1, 0}, {0, 0.5}}, {{1, 0}, {1, 0.5}}, {{0, -1}, {0.5, 0}}, {{0, 1}, {0.5, 1}}, // edges
}

@(private = "file")
_rect_point :: proc(r: engine.Rect, m: matrix[4, 4]f32, at: [2]f32) -> [3]f32 {
	return engine.rect_apply(m, {r.pos.x + r.size.x * at.x, r.pos.y + r.size.y * at.y})
}

// Apply a handle's drag: start from the grab-time values, then move or
// resize by the total offset. The world offset is a canvas offset (one unit
// per canvas unit), brought into the parent's space so a child of a rotated
// or scaled parent drags along its own axes.
@(private = "file")
_apply_drag :: proc(rt: ^engine.RectTransform, h: ^_Rect_Handle, d: handles.Drag, parent_xform: matrix[4, 4]f32) {
	rt.anchored_position = _drag_start.anchored_position
	rt.size_delta = _drag_start.size_delta
	delta := engine.rect_apply_dir(linalg.inverse(parent_xform), d.delta.xy)
	if h == nil {
		mhgui.rect_drag_move(rt, delta)
	} else {
		mhgui.rect_drag_edges(rt, h.sides, delta)
	}
}

@(private = "file")
_drag_begin :: proc(tH: engine.Transform_Handle, rt: ^engine.RectTransform) {
	_drag_start = rt^
	owned, _ := engine.transform_get_comp(tH, engine.RectTransform)
	targets := [?]undo.Edit_Target{
		undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)),
		undo.edit_target_pooled(owned.handle, &rt.size_delta, typeid_of([2]f32)),
	}
	_drag_edit = undo.edit_session_begin(targets[:], "Rect Tool")
}

// The rect tool on the selected RectTransform: the rect outline, corner and
// edge handles that resize, the body that moves, the parent's anchor
// markers and the pivot ring.
@(on_draw_gizmos_selected={component=RectTransform})
rect_transform_gizmos :: proc(rt: ^engine.RectTransform) {
	tH := rt.owner
	canvas := _canvas_of(tH)
	if canvas == _NONE || canvas == tH do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	parent_tH := engine.Transform_Handle(t.parent.handle)

	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, engine.canvas_world_rect(canvas), &nodes)
	rect, parent: engine.Rect
	xform, parent_xform: matrix[4, 4]f32
	have_rect, have_parent: bool
	for n in nodes {
		if n.tH == tH { rect = n.rect; xform = n.xform; have_rect = true }
		if n.tH == parent_tH { parent = n.rect; parent_xform = n.xform; have_parent = true }
	}
	if !have_rect || !have_parent do return

	// Anchors on the parent rect (in the parent's space): one marker when
	// min == max, else four.
	a_lo := parent.pos + parent.size * rt.anchor_min
	a_hi := parent.pos + parent.size * rt.anchor_max
	anchor_size := handles.world_per_pixels(_rect_point(rect, parent_xform, {0.5, 0.5}), 10)
	anchor_at :: proc(m: matrix[4, 4]f32, p: [2]f32) -> [3]f32 {
		return engine.rect_apply(m, p)
	}
	if rt.anchor_min == rt.anchor_max {
		handles.triangle(anchor_at(parent_xform, a_lo), {0, -1, 0}, anchor_size, _COLOR_ANCHOR)
	} else {
		handles.triangle(anchor_at(parent_xform, a_lo), {1, 1, 0}, anchor_size, _COLOR_ANCHOR)
		handles.triangle(anchor_at(parent_xform, {a_hi.x, a_lo.y}), {-1, 1, 0}, anchor_size, _COLOR_ANCHOR)
		handles.triangle(anchor_at(parent_xform, a_hi), {-1, -1, 0}, anchor_size, _COLOR_ANCHOR)
		handles.triangle(anchor_at(parent_xform, {a_lo.x, a_hi.y}), {1, -1, 0}, anchor_size, _COLOR_ANCHOR)
	}

	// The rect with its own rotation and scale applied, then the handles on
	// its corners and edge midpoints.
	corners := engine.rect_corners(rect, xform)
	handles.rect(corners, _COLOR_RECT)

	body := handles.quad(_handle_id(tH, 9), corners, _PLANE_NORMAL)
	if body.started do _drag_begin(tH, rt)
	if body.dragging do _apply_drag(rt, nil, body, parent_xform)
	if body.released do undo.edit_session_end(&_drag_edit)

	for &h, i in _RECT_HANDLES {
		d := handles.dot(_handle_id(tH, u64(i) + 1), _rect_point(rect, xform, h.at), _PLANE_NORMAL)
		if d.started do _drag_begin(tH, rt)
		if d.dragging do _apply_drag(rt, &h, d, parent_xform)
		if d.released do undo.edit_session_end(&_drag_edit)
	}

	// Pivot ring, drawn last so it reads over the handles.
	pivot := _rect_point(rect, xform, rt.pivot)
	handles.circle(pivot, _PLANE_NORMAL, handles.world_per_pixels(pivot, 5), _COLOR_PIVOT)
}
