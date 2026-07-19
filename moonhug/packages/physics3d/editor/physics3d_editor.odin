package physics3d_editor

// Collider wireframes in the scene view via the @(on_draw_gizmos_selected)
// hook — drawn only for selected transforms, like Unity. Full 3D: points go
// through the owner's world rotation (scale ignored, matching the sync).

import "core:math"
import "core:math/linalg"
import physics3d "packages:physics3d"
import "../../../engine"
import gfx "../../../engine/gfx"

// Unity's collider gizmo green.
_COLLIDER_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

_SEGMENTS :: 32

_Gizmo_Frame :: struct {
	origin: [3]f32,
	rot:    quaternion128,
}

_frame_of :: proc(owner: engine.Transform_Handle) -> _Gizmo_Frame {
	tw := engine.transform_world(owner)
	return {origin = tw.position, rot = engine.quat_to_native(tw.rotation)}
}

_point :: proc(f: _Gizmo_Frame, p: [3]f32) -> [3]f32 {
	return f.origin + linalg.quaternion128_mul_vector3(f.rot, p)
}

_line :: proc(f: _Gizmo_Frame, a, b: [3]f32) {
	gfx.draw_line(_point(f, a), _point(f, b), _COLLIDER_COLOR)
}

// Arc around `center` in the plane spanned by u/v, radians from/sweep.
_arc :: proc(f: _Gizmo_Frame, center: [3]f32, u, v: [3]f32, radius: f32, from, sweep: f32, segments: int) {
	prev := center + radius * (math.cos(from) * u + math.sin(from) * v)
	for i in 1 ..= segments {
		a := from + sweep * f32(i) / f32(segments)
		next := center + radius * (math.cos(a) * u + math.sin(a) * v)
		_line(f, prev, next)
		prev = next
	}
}

_circle :: proc(f: _Gizmo_Frame, center: [3]f32, u, v: [3]f32, radius: f32) {
	_arc(f, center, u, v, radius, 0, math.TAU, _SEGMENTS)
}

@(on_draw_gizmos_selected={component=BoxCollider})
box_collider_gizmos :: proc(c: ^physics3d.BoxCollider) {
	f := _frame_of(c.owner)
	h := c.size * 0.5
	o := c.center
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
		_line(f, corners[e[0]], corners[e[1]])
	}
}

@(on_draw_gizmos_selected={component=SphereCollider})
sphere_collider_gizmos :: proc(c: ^physics3d.SphereCollider) {
	f := _frame_of(c.owner)
	x := [3]f32{1, 0, 0}
	y := [3]f32{0, 1, 0}
	z := [3]f32{0, 0, 1}
	_circle(f, c.center, x, y, c.radius)
	_circle(f, c.center, x, z, c.radius)
	_circle(f, c.center, y, z, c.radius)
}

@(on_draw_gizmos_selected={component=CapsuleCollider})
capsule_collider_gizmos :: proc(c: ^physics3d.CapsuleCollider) {
	f := _frame_of(c.owner)
	axis, u, v: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}; u = {0, 1, 0}; v = {0, 0, 1}
	case .Y_Axis: axis = {0, 1, 0}; u = {1, 0, 0}; v = {0, 0, 1}
	case .Z_Axis: axis = {0, 0, 1}; u = {1, 0, 0}; v = {0, 1, 0}
	}
	half := max(c.height * 0.5 - c.radius, 0)
	c1 := c.center + axis * half
	c2 := c.center - axis * half

	// Rings at the hemisphere centers.
	_circle(f, c1, u, v, c.radius)
	_circle(f, c2, u, v, c.radius)
	// Side lines.
	for side in ([4][3]f32{u, -u, v, -v}) {
		_line(f, c1 + side * c.radius, c2 + side * c.radius)
	}
	// End caps: half-arcs in the axis/u and axis/v planes.
	_arc(f, c1, u, axis, c.radius, 0, math.PI, _SEGMENTS / 2)
	_arc(f, c1, v, axis, c.radius, 0, math.PI, _SEGMENTS / 2)
	_arc(f, c2, u, axis, c.radius, math.PI, math.PI, _SEGMENTS / 2)
	_arc(f, c2, v, axis, c.radius, math.PI, math.PI, _SEGMENTS / 2)
}
