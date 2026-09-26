package physics2d

// Collider outlines, shared by two callers: the editor's selected-object
// gizmos (packages/physics2d/editor delegates here) and the in-app debug
// view — the DebugDraw phase subscriber draws EVERY enabled collider when
// engine.debug_draw_enabled is on. Outlines in the XY plane at the owner's
// z, turned by its world z rotation only, matching the sync's v1 rules.
// Drawn through engine/gizmos.

import "core:math"
import "core:math/linalg"
import "moonhug:engine"
import "moonhug:engine/gizmos"

// Unity's 2D collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

// The owner's position and world z rotation: the space 2D colliders live in.
collider_space :: proc(owner: engine.Transform_Handle) -> matrix[4, 4]f32 {
	tw := engine.transform_world(owner)
	angle := math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z)
	return linalg.matrix4_translate_f32(tw.position) * linalg.matrix4_rotate_f32(angle, {0, 0, 1})
}

draw_box_collider_wires :: proc(c: ^BoxCollider2D, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.with_matrix(collider_space(c.owner))
	size, o := box_scaled(c, collider_scale(c.owner))
	gizmos.wire_rect({o.x, o.y, 0}, size)
}

draw_circle_collider_wires :: proc(c: ^CircleCollider2D, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.with_matrix(collider_space(c.owner))
	radius, o := circle_scaled(c, collider_scale(c.owner))
	gizmos.wire_circle({o.x, o.y, 0}, {0, 0, 1}, radius)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider2D, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.with_matrix(collider_space(c.owner))
	size, o := capsule_scaled(c, collider_scale(c.owner))
	radius, half: f32
	axis, side: [2]f32
	cap_from: f32
	if c.direction == .Vertical {
		radius = size.x * 0.5
		half = max(size.y * 0.5 - radius, 0)
		axis = {0, 1}
		side = {1, 0}
		cap_from = 0 // top cap sweeps 0..pi, bottom pi..2pi
	} else {
		radius = size.y * 0.5
		half = max(size.x * 0.5 - radius, 0)
		axis = {1, 0}
		side = {0, 1}
		cap_from = math.PI * 0.5
	}
	v3 :: proc(p: [2]f32) -> [3]f32 { return {p.x, p.y, 0} }
	c1 := o + axis * half // cap center on the +axis end
	c2 := o - axis * half
	from1 := [3]f32{math.cos(cap_from), math.sin(cap_from), 0}
	gizmos.wire_arc(v3(c1), {0, 0, 1}, from1, math.PI, radius)
	gizmos.wire_arc(v3(c2), {0, 0, 1}, -from1, math.PI, radius)
	gizmos.line(v3(c1 + side * radius), v3(c2 + side * radius))
	gizmos.line(v3(c1 - side * radius), v3(c2 - side * radius))
}

// Every enabled collider as an outline (Unity's Physics Debug view, there is
// no selection in the app).
@(phase={key=DebugDraw, mode=App})
debug_draw :: proc() {
	w := engine.ctx_world()
	it := engine.pool_iterator(box_collider2_ds(w))
	for c, _ in engine.pool_next(&it) {
		if c.enabled do draw_box_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it2 := engine.pool_iterator(circle_collider2_ds(w))
	for c, _ in engine.pool_next(&it2) {
		if c.enabled do draw_circle_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it3 := engine.pool_iterator(capsule_collider2_ds(w))
	for c, _ in engine.pool_next(&it3) {
		if c.enabled do draw_capsule_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
}
