package physics3d

// Collider wireframes, shared by two callers: the editor's selected-object
// gizmos (packages/physics3d/editor delegates here) and the in-app debug
// view — @(debug_draw) draws EVERY enabled collider and runs when
// engine.debug_draw_enabled is on. Full 3D: points go through the owner's
// world rotation (scale ignored, matching the sync). Lines go through the
// gfx line API, so the caller must have an open pass with a world-space
// view_proj.

import "core:math"
import "core:math/linalg"
import "../../engine"
import gfx "../../engine/gfx"

// Unity's collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

_GIZ_SEGMENTS :: 32

_Giz_Frame :: struct {
	origin: [3]f32,
	rot:    quaternion128,
	color:  [4]f32,
}

_giz_frame :: proc(owner: engine.Transform_Handle, color: [4]f32) -> _Giz_Frame {
	tw := engine.transform_world(owner)
	return {origin = tw.position, rot = engine.quat_to_native(tw.rotation), color = color}
}

_giz_point :: proc(f: _Giz_Frame, p: [3]f32) -> [3]f32 {
	return f.origin + linalg.quaternion128_mul_vector3(f.rot, p)
}

_giz_line :: proc(f: _Giz_Frame, a, b: [3]f32) {
	gfx.draw_line(_giz_point(f, a), _giz_point(f, b), f.color)
}

// Arc around `center` in the plane spanned by u/v, radians from/sweep.
_giz_arc :: proc(f: _Giz_Frame, center: [3]f32, u, v: [3]f32, radius: f32, from, sweep: f32, segments: int) {
	prev := center + radius * (math.cos(from) * u + math.sin(from) * v)
	for i in 1 ..= segments {
		a := from + sweep * f32(i) / f32(segments)
		next := center + radius * (math.cos(a) * u + math.sin(a) * v)
		_giz_line(f, prev, next)
		prev = next
	}
}

_giz_circle :: proc(f: _Giz_Frame, center: [3]f32, u, v: [3]f32, radius: f32) {
	_giz_arc(f, center, u, v, radius, 0, math.TAU, _GIZ_SEGMENTS)
}

draw_box_collider_wires :: proc(c: ^BoxCollider, color: [4]f32) {
	f := _giz_frame(c.owner, color)
	size, o := box_scaled(c, collider_scale(c.owner))
	h := size * 0.5
	corners: [8][3]f32
	for i in 0 ..< 8 {
		corners[i] = o + {
			i & 1 == 0 ? -h.x : h.x,
			i & 2 == 0 ? -h.y : h.y,
			i & 4 == 0 ? -h.z : h.z,
		}
	}
	edges := [12][2]int{
		{0, 1}, {1, 3}, {3, 2}, {2, 0}, // bottom (z-)
		{4, 5}, {5, 7}, {7, 6}, {6, 4}, // top (z+)
		{0, 4}, {1, 5}, {2, 6}, {3, 7}, // verticals
	}
	for e in edges {
		_giz_line(f, corners[e[0]], corners[e[1]])
	}
}

draw_sphere_collider_wires :: proc(c: ^SphereCollider, color: [4]f32) {
	f := _giz_frame(c.owner, color)
	radius, o := sphere_scaled(c, collider_scale(c.owner))
	x := [3]f32{1, 0, 0}
	y := [3]f32{0, 1, 0}
	z := [3]f32{0, 0, 1}
	_giz_circle(f, o, x, y, radius)
	_giz_circle(f, o, x, z, radius)
	_giz_circle(f, o, y, z, radius)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider, color: [4]f32) {
	f := _giz_frame(c.owner, color)
	axis, u, v: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}; u = {0, 1, 0}; v = {0, 0, 1}
	case .Y_Axis: axis = {0, 1, 0}; u = {1, 0, 0}; v = {0, 0, 1}
	case .Z_Axis: axis = {0, 0, 1}; u = {1, 0, 0}; v = {0, 1, 0}
	}
	radius, height, o := capsule_scaled(c, collider_scale(c.owner))
	half := max(height * 0.5 - radius, 0)
	c1 := o + axis * half
	c2 := o - axis * half

	// Rings at the hemisphere centers.
	_giz_circle(f, c1, u, v, radius)
	_giz_circle(f, c2, u, v, radius)
	// Side lines.
	for side in ([4][3]f32{u, -u, v, -v}) {
		_giz_line(f, c1 + side * radius, c2 + side * radius)
	}
	// End caps: half-arcs in the axis/u and axis/v planes.
	_giz_arc(f, c1, u, axis, radius, 0, math.PI, _GIZ_SEGMENTS / 2)
	_giz_arc(f, c1, v, axis, radius, 0, math.PI, _GIZ_SEGMENTS / 2)
	_giz_arc(f, c2, u, axis, radius, math.PI, math.PI, _GIZ_SEGMENTS / 2)
	_giz_arc(f, c2, v, axis, radius, math.PI, math.PI, _GIZ_SEGMENTS / 2)
}

// Every enabled collider as a wireframe (Unity's Physics Debug view, there is
// no selection in the app).
@(debug_draw)
debug_draw :: proc() {
	w := engine.ctx_world()
	if pool := box_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_box_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
	if pool := sphere_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_sphere_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
	if pool := capsule_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_capsule_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
}
