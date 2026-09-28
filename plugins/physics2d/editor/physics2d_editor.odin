package physics2d_editor

// Collider outlines in the scene view via the @(on_draw_gizmos) hook — drawn
// only for objects in the selection (a parent selected counts). The outline
// geometry lives in the runtime package (packages/physics2d/gizmos.odin),
// shared with the in-app @(debug_draw) view — here only the selected-only
// policy and the color choice remain.
//
// In the Handles tool (T), bounds handles on the selected colliders resize
// them in their plane (@(on_scene_handles)), one undo step per drag.

import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import physics2d "moonhug:packages/physics2d"

@(on_draw_gizmos={component=BoxCollider2D})
box_collider_gizmos :: proc(c: ^physics2d.BoxCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_box_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=CircleCollider2D})
circle_collider_gizmos :: proc(c: ^physics2d.CircleCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_circle_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=CapsuleCollider2D})
capsule_collider_gizmos :: proc(c: ^physics2d.CapsuleCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_capsule_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

// --- Bounds handles --------------------------------------------------------------
// The handles work in the collider's space (collider_space) with scaled
// sizes, as the outlines do, on the X and Y axes only. A field changes only
// on the axes the drag changed, so a click without a move, or the scale
// round trip, never touches the others.

@(private = "file")
_AXES_2D :: handles.Axes{.X, .Y}

@(private = "file")
_edit: undo.Edit_Session

@(private = "file")
_edit_begin :: proc(targets: []undo.Edit_Target, label: string) {
	_edit = undo.edit_session_begin(targets, label)
	handles.on_drag_lost(proc(_: rawptr) { undo.edit_session_end(&_edit) })
}

@(private = "file")
_unscale :: proc(field: ^[2]f32, now, before: [3]f32, s: [2]f32) {
	for i in 0 ..< 2 do _unscale1(&field[i], now[i], before[i], s[i])
}

@(private = "file")
_unscale1 :: proc(field: ^f32, now, before, s: f32) {
	if now != before && s > 1e-6 do field^ = now / s
}

// A box-shaped collider (box, capsule): its size and offset as box bounds.
@(private = "file")
_box_handles :: proc(c: ^engine.CompData, size_field, offset_field: ^[2]f32, size2, offset2, s: [2]f32, label: string) {
	h, ok := engine.comp_handle_of(c)
	if !ok do return
	gizmos.with_matrix(physics2d.collider_space(c.owner))
	size0 := [3]f32{size2.x, size2.y, 0}
	center0 := [3]f32{offset2.x, offset2.y, 0}
	size, center := size0, center0
	d := handles.box_bounds(handles.id_of(h), &center, &size, _AXES_2D, physics2d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, size_field, typeid_of([2]f32)),
			undo.edit_target_pooled(h, offset_field, typeid_of([2]f32)),
		}
		_edit_begin(targets[:], label)
	}
	if d.dragging || d.released {
		_unscale(size_field, size, size0, s)
		_unscale(offset_field, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(on_scene_handles={component=BoxCollider2D})
box_collider_handles :: proc(c: ^physics2d.BoxCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	s := physics2d.collider_scale(c.owner)
	size, offset := physics2d.box_scaled(c, s)
	_box_handles(&c.base, &c.size, &c.offset, size, offset, s, "Edit Box Collider 2D")
}

// The capsule's size is its bounding box, so box bounds edit it.
@(on_scene_handles={component=CapsuleCollider2D})
capsule_collider_handles :: proc(c: ^physics2d.CapsuleCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	s := physics2d.collider_scale(c.owner)
	size, offset := physics2d.capsule_scaled(c, s)
	_box_handles(&c.base, &c.size, &c.offset, size, offset, s, "Edit Capsule Collider 2D")
}

@(on_scene_handles={component=CircleCollider2D})
circle_collider_handles :: proc(c: ^physics2d.CircleCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics2d.collider_scale(c.owner)
	gizmos.with_matrix(physics2d.collider_space(c.owner))
	radius0, offset2 := physics2d.circle_scaled(c, s)
	center0 := [3]f32{offset2.x, offset2.y, 0}
	radius, center := radius0, center0
	d := handles.sphere_bounds(handles.id_of(h), &center, &radius, _AXES_2D, physics2d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.offset, typeid_of([2]f32)),
		}
		_edit_begin(targets[:], "Edit Circle Collider 2D")
	}
	if d.dragging || d.released {
		_unscale1(&c.radius, radius, radius0, max(s.x, s.y))
		_unscale(&c.offset, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}
