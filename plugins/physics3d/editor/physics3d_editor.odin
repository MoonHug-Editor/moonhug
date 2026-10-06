package physics3d_editor

// Collider wireframes in the scene view via the @(on_draw_gizmos) hook — drawn
// only for objects in the selection (a parent selected counts). The wire geometry
// lives in the runtime package (packages/physics3d/gizmos.odin), shared with
// the in-app @(debug_draw) view — here only the selected-only policy and the
// color choice remain.
//
// In the Handles tool (T), bounds handles on the selected colliders resize
// them (@(on_scene_handles)), one undo step per drag.

import "moonhug:packages/engine"
import "moonhug:host/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import physics3d "moonhug:packages/physics3d"

@(on_draw_gizmos={component=BoxCollider})
box_collider_gizmos :: proc(c: ^physics3d.BoxCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_box_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=SphereCollider})
sphere_collider_gizmos :: proc(c: ^physics3d.SphereCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_sphere_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=CapsuleCollider})
capsule_collider_gizmos :: proc(c: ^physics3d.CapsuleCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_capsule_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

// --- Bounds handles --------------------------------------------------------------
// The handles work in the collider's space with scaled sizes, as the wires do.
// A field changes only on the axes the drag changed, so a click without a
// move, or the scale round trip, never touches the others.

@(private = "file")
_edit: undo.Edit_Session

@(private = "file")
_edit_begin :: proc(targets: []undo.Edit_Target, label: string) {
	_edit = undo.edit_session_begin(targets, label)
	handles.on_drag_lost(proc(_: rawptr) { undo.edit_session_end(&_edit) })
}

@(private = "file")
_unscale :: proc(field: ^[3]f32, now, before, s: [3]f32) {
	for i in 0 ..< 3 do _unscale1(&field[i], now[i], before[i], s[i])
}

@(private = "file")
_unscale1 :: proc(field: ^f32, now, before, s: f32) {
	if now != before && s > 1e-6 do field^ = now / s
}

@(private = "file")
_axis :: proc(d: physics3d.Capsule_Direction) -> handles.Axis {
	switch d {
	case .X_Axis: return .X
	case .Y_Axis: return .Y
	case .Z_Axis: return .Z
	}
	return .Y
}

@(on_scene_handles={component=BoxCollider})
box_collider_handles :: proc(c: ^physics3d.BoxCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	size0, center0 := physics3d.box_scaled(c, s)
	size, center := size0, center0
	d := handles.box_bounds(handles.id_of(h), &center, &size, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.size, typeid_of([3]f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		_edit_begin(targets[:], "Edit Box Collider")
	}
	if d.dragging || d.released {
		_unscale(&c.size, size, size0, s)
		_unscale(&c.center, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(on_scene_handles={component=SphereCollider})
sphere_collider_handles :: proc(c: ^physics3d.SphereCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius0, center0 := physics3d.sphere_scaled(c, s)
	radius, center := radius0, center0
	d := handles.sphere_bounds(handles.id_of(h), &center, &radius, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		_edit_begin(targets[:], "Edit Sphere Collider")
	}
	if d.dragging || d.released {
		_unscale1(&c.radius, radius, radius0, max(s.x, s.y, s.z))
		_unscale(&c.center, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(on_scene_handles={component=CapsuleCollider})
capsule_collider_handles :: proc(c: ^physics3d.CapsuleCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius0, height0, center0 := physics3d.capsule_scaled(c, s)
	radius, height, center := radius0, height0, center0
	axis := _axis(c.direction)
	d := handles.capsule_bounds(handles.id_of(h), &center, &radius, &height, axis, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.height, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		_edit_begin(targets[:], "Edit Capsule Collider")
	}
	if d.dragging || d.released {
		// The scale capsule_scaled applies: the long axis for the height,
		// the larger of the other two for the radius.
		i := int(axis)
		_unscale1(&c.radius, radius, radius0, max(s[(i + 1) % 3], s[(i + 2) % 3]))
		_unscale1(&c.height, height, height0, s[i])
		_unscale(&c.center, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}
