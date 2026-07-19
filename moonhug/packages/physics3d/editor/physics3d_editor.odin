package physics3d_editor

// Collider wireframes in the scene view via the @(on_draw_gizmos_selected)
// hook — drawn only for selected transforms, like Unity. The wire geometry
// lives in the runtime package (packages/physics3d/gizmos.odin), shared with
// the in-app @(debug_draw) view — here only the selected-only policy and the
// color choice remain.

import physics3d "packages:physics3d"

@(on_draw_gizmos_selected={component=BoxCollider})
box_collider_gizmos :: proc(c: ^physics3d.BoxCollider) {
	physics3d.draw_box_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos_selected={component=SphereCollider})
sphere_collider_gizmos :: proc(c: ^physics3d.SphereCollider) {
	physics3d.draw_sphere_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos_selected={component=CapsuleCollider})
capsule_collider_gizmos :: proc(c: ^physics3d.CapsuleCollider) {
	physics3d.draw_capsule_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}
