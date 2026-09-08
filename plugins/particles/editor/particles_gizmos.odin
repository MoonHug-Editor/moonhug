package particles_editor

// Emission shape gizmo (Unity's): the selected ParticleSystem draws its
// shape as wireframe lines in the emitter's world frame — emission is along
// local +Z, scale is ignored exactly like the sim's shape sampling. Runs
// inside the scene view's pass (world-space view_proj is set).

import "core:math"
import "core:math/linalg"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"
import particles "moonhug:packages/particles"

SHAPE_GIZMO_COLOR :: [4]f32{0.4, 0.75, 1, 1}
_SHAPE_GIZMO_SEGMENTS :: 32
// Cone spread lines and hemisphere/edge direction hints use this length.
_SHAPE_GIZMO_LENGTH :: f32(1)

@(private = "file")
_Gz :: struct {
	origin: [3]f32,
	rot:    quaternion128,
}

@(private = "file")
_gz_point :: proc(g: _Gz, p: [3]f32) -> [3]f32 {
	return g.origin + linalg.quaternion128_mul_vector3(g.rot, p)
}

@(private = "file")
_gz_line :: proc(g: _Gz, a, b: [3]f32) {
	gfx.draw_line(_gz_point(g, a), _gz_point(g, b), SHAPE_GIZMO_COLOR)
}

// Circle around `center` in the plane spanned by u/v.
@(private = "file")
_gz_circle :: proc(g: _Gz, center: [3]f32, u, v: [3]f32, radius: f32) {
	prev := center + radius * u
	for i in 1 ..= _SHAPE_GIZMO_SEGMENTS {
		a := math.TAU * f32(i) / _SHAPE_GIZMO_SEGMENTS
		next := center + radius * (math.cos(a) * u + math.sin(a) * v)
		_gz_line(g, prev, next)
		prev = next
	}
}

@(on_draw_gizmos_selected={component=ParticleSystem})
particle_shape_gizmos :: proc(ps: ^particles.ParticleSystem) {
	tw := engine.transform_world(engine.Transform_Handle(ps.owner))
	g := _Gz{origin = tw.position, rot = engine.quat_to_native(tw.rotation)}
	X :: [3]f32{1, 0, 0}
	Y :: [3]f32{0, 1, 0}
	Z :: [3]f32{0, 0, 1}
	r := ps.shape_radius

	switch ps.shape {
	case .Point:
		s := f32(0.1)
		_gz_line(g, {-s, 0, 0}, {s, 0, 0})
		_gz_line(g, {0, -s, 0}, {0, s, 0})
		_gz_line(g, {0, 0, 0}, {0, 0, _SHAPE_GIZMO_LENGTH * 0.5})
	case .Cone:
		// Base disc + the spread silhouette: four slanted lines to a far
		// disc widened by the cone angle over the gizmo length.
		_gz_circle(g, {}, X, Y, r)
		far_r := r + math.tan(math.to_radians(clamp(ps.shape_angle, 0, 89))) * _SHAPE_GIZMO_LENGTH
		far_c := [3]f32{0, 0, _SHAPE_GIZMO_LENGTH}
		_gz_circle(g, far_c, X, Y, far_r)
		for i in 0 ..< 4 {
			a := math.TAU * f32(i) / 4
			dir := [3]f32{math.cos(a), math.sin(a), 0}
			_gz_line(g, dir * r, far_c + dir * far_r)
		}
	case .Sphere:
		_gz_circle(g, {}, X, Y, r)
		_gz_circle(g, {}, X, Z, r)
		_gz_circle(g, {}, Y, Z, r)
	case .Hemisphere:
		_gz_circle(g, {}, X, Y, r)
		// Half arcs on the +Z side.
		for pair in ([2][2][3]f32{{X, Z}, {Y, Z}}) {
			prev := r * pair[0]
			for i in 1 ..= _SHAPE_GIZMO_SEGMENTS / 2 {
				a := math.PI * f32(i) / (_SHAPE_GIZMO_SEGMENTS / 2)
				next := r * (math.cos(a) * pair[0] + math.sin(a) * pair[1])
				// sin >= 0 over 0..PI keeps the arc on +Z.
				_gz_line(g, prev, next)
				prev = next
			}
		}
	case .Circle:
		_gz_circle(g, {}, X, Y, r)
	case .Edge:
		_gz_line(g, {-r, 0, 0}, {r, 0, 0})
		_gz_line(g, {}, {0, 0, _SHAPE_GIZMO_LENGTH * 0.5})
	case .Box:
		h := ps.shape_box * 0.5
		corners := [8][3]f32{
			{-h.x, -h.y, -h.z}, {h.x, -h.y, -h.z}, {h.x, h.y, -h.z}, {-h.x, h.y, -h.z},
			{-h.x, -h.y, h.z}, {h.x, -h.y, h.z}, {h.x, h.y, h.z}, {-h.x, h.y, h.z},
		}
		for i in 0 ..< 4 {
			j := (i + 1) % 4
			_gz_line(g, corners[i], corners[j])
			_gz_line(g, corners[i + 4], corners[j + 4])
			_gz_line(g, corners[i], corners[i + 4])
		}
	}
}
