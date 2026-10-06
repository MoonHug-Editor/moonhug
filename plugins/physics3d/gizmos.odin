package physics3d

// Collider wireframes, shared by two callers: the editor's selected-object
// gizmos (packages/physics3d/editor delegates here) and the in-app debug
// view — the DebugDraw phase subscriber draws EVERY enabled collider when
// engine.debug_draw_enabled is on. Full 3D: shapes go through the owner's
// world position and rotation (scale ignored, matching the sync: the sizes
// are scaled already). Drawn through host/gizmos.

import "moonhug:packages/engine"
import "moonhug:host/gizmos"

// Unity's collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

draw_box_collider_wires :: proc(c: ^BoxCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	size, o := box_scaled(c, collider_scale(c.owner))
	gizmos.wire_box(o, size)
}

draw_sphere_collider_wires :: proc(c: ^SphereCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius, o := sphere_scaled(c, collider_scale(c.owner))
	gizmos.wire_sphere(o, radius)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	axis: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}
	case .Y_Axis: axis = {0, 1, 0}
	case .Z_Axis: axis = {0, 0, 1}
	}
	radius, height, o := capsule_scaled(c, collider_scale(c.owner))
	half := max(height * 0.5 - radius, 0)
	gizmos.wire_capsule(o - axis * half, o + axis * half, radius)
}

// Every enabled collider as a wireframe (Unity's Physics Debug view, there is
// no selection in the app).
@(phase={key=DebugDraw, mode=App})
debug_draw :: proc() {
	w := engine.ctx_world()
	it := engine.pool_iterator(box_colliders(w))
	for c, _ in engine.pool_next(&it) {
		if c.enabled do draw_box_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it2 := engine.pool_iterator(sphere_colliders(w))
	for c, _ in engine.pool_next(&it2) {
		if c.enabled do draw_sphere_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it3 := engine.pool_iterator(capsule_colliders(w))
	for c, _ in engine.pool_next(&it3) {
		if c.enabled do draw_capsule_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
}
