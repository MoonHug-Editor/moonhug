package physics2d_editor

// Collider outlines in the scene view via the @(on_draw_gizmos_selected)
// hook — drawn only for selected transforms, like Unity. The outline
// geometry lives in the runtime package (packages/physics2d/gizmos.odin),
// shared with the in-app @(debug_draw) view — here only the selected-only
// policy and the color choice remain.

import physics2d "moonhug:packages/physics2d"

@(on_draw_gizmos_selected={component=BoxCollider2D})
box_collider_gizmos :: proc(c: ^physics2d.BoxCollider2D) {
	physics2d.draw_box_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos_selected={component=CircleCollider2D})
circle_collider_gizmos :: proc(c: ^physics2d.CircleCollider2D) {
	physics2d.draw_circle_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos_selected={component=CapsuleCollider2D})
capsule_collider_gizmos :: proc(c: ^physics2d.CapsuleCollider2D) {
	physics2d.draw_capsule_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}
