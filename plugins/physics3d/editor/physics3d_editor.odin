package physics3d_editor

// Collider wireframes in the scene view via the @(on_draw_gizmos) hook — drawn
// only for objects in the selection (a parent selected counts), like Unity. The wire geometry
// lives in the runtime package (packages/physics3d/gizmos.odin), shared with
// the in-app @(debug_draw) view — here only the selected-only policy and the
// color choice remain.

import physics3d "moonhug:packages/physics3d"
import "moonhug:editor/handles"

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
