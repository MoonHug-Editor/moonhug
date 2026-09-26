package particles_editor

// Emission shape gizmo (Unity's): the selected ParticleSystem draws its
// shape as wireframe lines in the emitter's world frame — emission is along
// local +Z, scale is ignored exactly like the sim's shape sampling. Drawn with
// engine/gizmos from the @(on_draw_gizmos) hook, for systems in the selection.

import "core:math"
import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"
import particles "moonhug:packages/particles"

SHAPE_GIZMO_COLOR :: [4]f32{0.4, 0.75, 1, 1}
// Cone spread lines and hemisphere/edge direction hints use this length.
_SHAPE_GIZMO_LENGTH :: f32(1)

@(on_draw_gizmos={component=ParticleSystem})
particle_shape_gizmos :: proc(ps: ^particles.ParticleSystem, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(SHAPE_GIZMO_COLOR)
	gizmos.in_local_space(engine.Transform_Handle(ps.owner), use_scale = false)
	X :: [3]f32{1, 0, 0}
	Y :: [3]f32{0, 1, 0}
	Z :: [3]f32{0, 0, 1}
	r := ps.shape_radius

	switch ps.shape {
	case .Point:
		s := f32(0.1)
		gizmos.line({-s, 0, 0}, {s, 0, 0})
		gizmos.line({0, -s, 0}, {0, s, 0})
		gizmos.line({0, 0, 0}, {0, 0, _SHAPE_GIZMO_LENGTH * 0.5})
	case .Cone:
		// Base disc + the spread silhouette: four slanted lines to a far
		// disc widened by the cone angle over the gizmo length.
		gizmos.wire_circle({}, Z, r)
		far_r := r + math.tan(math.to_radians(clamp(ps.shape_angle, 0, 89))) * _SHAPE_GIZMO_LENGTH
		far_c := [3]f32{0, 0, _SHAPE_GIZMO_LENGTH}
		gizmos.wire_circle(far_c, Z, far_r)
		for i in 0 ..< 4 {
			a := math.TAU * f32(i) / 4
			dir := [3]f32{math.cos(a), math.sin(a), 0}
			gizmos.line(dir * r, far_c + dir * far_r)
		}
	case .Sphere:
		gizmos.wire_sphere({}, r)
	case .Hemisphere:
		gizmos.wire_circle({}, Z, r)
		// Half arcs on the +Z side.
		gizmos.wire_arc({}, Y, X, -math.PI, r)
		gizmos.wire_arc({}, X, Y, math.PI, r)
	case .Circle:
		gizmos.wire_circle({}, Z, r)
	case .Edge:
		gizmos.line({-r, 0, 0}, {r, 0, 0})
		gizmos.line({}, {0, 0, _SHAPE_GIZMO_LENGTH * 0.5})
	case .Box:
		gizmos.wire_box({}, ps.shape_box)
	}
}
