package physics2d

// Collider outlines, shared by two callers: the editor's selected-object
// gizmos (packages/physics2d/editor delegates here) and the in-app debug
// view — the DebugDraw phase subscriber draws EVERY enabled collider when
// engine.debug_draw_enabled is on. World-space lines in the XY plane at the
// owner's z, matching the sync's v1 rules. Lines go through the gfx line
// API, so the caller must have an open pass with a world-space view_proj.

import "core:math"
import "../../engine"
import gfx "../../engine/gfx"

// Unity's 2D collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

_GIZ_SEGMENTS :: 32

_Giz_Frame :: struct {
	origin: [3]f32, // owner world position
	angle:  f32,    // owner world z rotation, radians
	color:  [4]f32,
}

_giz_frame :: proc(owner: engine.Transform_Handle, color: [4]f32) -> _Giz_Frame {
	tw := engine.transform_world(owner)
	return {
		origin = tw.position,
		angle  = math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z),
		color  = color,
	}
}

// Collider-local 2D point -> world.
_giz_point :: proc(f: _Giz_Frame, p: [2]f32) -> [3]f32 {
	s, c := math.sin(f.angle), math.cos(f.angle)
	return f.origin + {p.x * c - p.y * s, p.x * s + p.y * c, 0}
}

_giz_line :: proc(f: _Giz_Frame, a, b: [2]f32) {
	gfx.draw_line(_giz_point(f, a), _giz_point(f, b), f.color)
}

// Arc around `center`, radians from `from` over `sweep`.
_giz_arc :: proc(f: _Giz_Frame, center: [2]f32, radius: f32, from, sweep: f32, segments: int) {
	prev := center + radius * [2]f32{math.cos(from), math.sin(from)}
	for i in 1 ..= segments {
		a := from + sweep * f32(i) / f32(segments)
		next := center + radius * [2]f32{math.cos(a), math.sin(a)}
		_giz_line(f, prev, next)
		prev = next
	}
}

draw_box_collider_wires :: proc(c: ^BoxCollider2D, color: [4]f32) {
	f := _giz_frame(c.owner, color)
	size, o := box_scaled(c, collider_scale(c.owner))
	h := size * 0.5
	corners := [4][2]f32{
		o + {-h.x, -h.y}, o + {h.x, -h.y},
		o + {h.x, h.y}, o + {-h.x, h.y},
	}
	for i in 0 ..< 4 {
		_giz_line(f, corners[i], corners[(i + 1) % 4])
	}
}

draw_circle_collider_wires :: proc(c: ^CircleCollider2D, color: [4]f32) {
	f := _giz_frame(c.owner, color)
	radius, o := circle_scaled(c, collider_scale(c.owner))
	_giz_arc(f, o, radius, 0, math.TAU, _GIZ_SEGMENTS)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider2D, color: [4]f32) {
	f := _giz_frame(c.owner, color)
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
	c1 := o + axis * half // cap center on the +axis end
	c2 := o - axis * half
	_giz_arc(f, c1, radius, cap_from, math.PI, _GIZ_SEGMENTS / 2)
	_giz_arc(f, c2, radius, cap_from + math.PI, math.PI, _GIZ_SEGMENTS / 2)
	_giz_line(f, c1 + side * radius, c2 + side * radius)
	_giz_line(f, c1 - side * radius, c2 - side * radius)
}

// Every enabled collider as an outline (Unity's Physics Debug view, there is
// no selection in the app).
@(phase={key=DebugDraw, mode=App})
debug_draw :: proc() {
	w := engine.ctx_world()
	if pool := box_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_box_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
	if pool := circle_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_circle_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
	if pool := capsule_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if slot.alive && slot.data.enabled do draw_capsule_collider_wires(&slot.data, COLLIDER_GIZMO_COLOR)
		}
	}
}
