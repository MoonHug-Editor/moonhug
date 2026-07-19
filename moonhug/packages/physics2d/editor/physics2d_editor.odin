package physics2d_editor

// Collider outlines in the scene view via the @(draw_gizmos_selected) hook —
// drawn only for selected transforms, like Unity. World-space lines in the
// XY plane at the owner's z; matches the sync's v1 rules (scale ignored).

import "core:math"
import physics2d "packages:physics2d"
import "../../../engine"
import gfx "../../../engine/gfx"

// Unity's 2D collider gizmo green.
_COLLIDER_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

_CIRCLE_SEGMENTS :: 32

_Gizmo_Frame :: struct {
	origin: [3]f32, // owner world position
	angle:  f32,    // owner world z rotation, radians
}

_frame_of :: proc(owner: engine.Transform_Handle) -> _Gizmo_Frame {
	tw := engine.transform_world(owner)
	return {
		origin = tw.position,
		angle  = math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z),
	}
}

// Collider-local 2D point -> world.
_point :: proc(f: _Gizmo_Frame, p: [2]f32) -> [3]f32 {
	s, c := math.sin(f.angle), math.cos(f.angle)
	return f.origin + {p.x * c - p.y * s, p.x * s + p.y * c, 0}
}

_line :: proc(f: _Gizmo_Frame, a, b: [2]f32) {
	gfx.draw_line(_point(f, a), _point(f, b), _COLLIDER_COLOR)
}

// Arc around `center`, radians from `from` over `sweep`.
_arc :: proc(f: _Gizmo_Frame, center: [2]f32, radius: f32, from, sweep: f32, segments: int) {
	prev := center + radius * [2]f32{math.cos(from), math.sin(from)}
	for i in 1 ..= segments {
		a := from + sweep * f32(i) / f32(segments)
		next := center + radius * [2]f32{math.cos(a), math.sin(a)}
		_line(f, prev, next)
		prev = next
	}
}

@(on_draw_gizmos_selected={component=BoxCollider2D})
box_collider_gizmos :: proc(c: ^physics2d.BoxCollider2D) {
	f := _frame_of(c.owner)
	size, o := physics2d.box_scaled(c, physics2d.collider_scale(c.owner))
	h := size * 0.5
	corners := [4][2]f32{
		o + {-h.x, -h.y}, o + {h.x, -h.y},
		o + {h.x, h.y}, o + {-h.x, h.y},
	}
	for i in 0 ..< 4 {
		_line(f, corners[i], corners[(i + 1) % 4])
	}
}

@(on_draw_gizmos_selected={component=CircleCollider2D})
circle_collider_gizmos :: proc(c: ^physics2d.CircleCollider2D) {
	f := _frame_of(c.owner)
	radius, o := physics2d.circle_scaled(c, physics2d.collider_scale(c.owner))
	_arc(f, o, radius, 0, math.TAU, _CIRCLE_SEGMENTS)
}

@(on_draw_gizmos_selected={component=CapsuleCollider2D})
capsule_collider_gizmos :: proc(c: ^physics2d.CapsuleCollider2D) {
	f := _frame_of(c.owner)
	size, o := physics2d.capsule_scaled(c, physics2d.collider_scale(c.owner))
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
	c1 := o + axis * half // cap center on the +axis end
	c2 := o - axis * half
	_arc(f, c1, radius, cap_from, math.PI, _CIRCLE_SEGMENTS / 2)
	_arc(f, c2, radius, cap_from + math.PI, math.PI, _CIRCLE_SEGMENTS / 2)
	_line(f, c1 + side * radius, c2 + side * radius)
	_line(f, c1 - side * radius, c2 - side * radius)
}
