package physics2d_editor

// Joint gizmos in the Scene window, for selected objects: a hinge's pivot, a
// distance joint's two anchors and the line between them, a fixed joint's
// line to its other body. Drawn where the anchors are now, in the XY plane.

import "moonhug:packages/engine"
import "moonhug:libs/gizmos"
import "moonhug:editor/handles"
import physics2d "moonhug:packages/physics2d"

// A screen-sized ring at `p`, at z.
@(private = "file")
_ring :: proc(p: [2]f32, z: f32) {
	at := [3]f32{p.x, p.y, z}
	gizmos.wire_circle(at, {0, 0, 1}, gizmos.helper_pixel(at, 6))
}

@(comp_on_draw_gizmos={component=HingeJoint2D})
comp_on_draw_gizmos_HingeJoint2D :: proc(j: ^physics2d.HingeJoint2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(physics2d.COLLIDER_GIZMO_COLOR)
	z := engine.transform_world(j.owner).position.z
	pivot := physics2d.joint_anchor_world(j.owner, j.anchor)
	_ring(pivot, z)
	if other := physics2d.joint_connected_object(j.connected); other != {} {
		gizmos.line({pivot.x, pivot.y, z}, engine.transform_world(other).position)
	}
}

@(comp_on_draw_gizmos={component=DistanceJoint2D})
comp_on_draw_gizmos_DistanceJoint2D :: proc(j: ^physics2d.DistanceJoint2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(physics2d.COLLIDER_GIZMO_COLOR)
	z := engine.transform_world(j.owner).position.z
	from := physics2d.joint_anchor_world(j.owner, j.anchor)
	to := j.connected_anchor
	if other := physics2d.joint_connected_object(j.connected); other != {} do to = physics2d.joint_anchor_world(other, j.connected_anchor)
	_ring(from, z)
	_ring(to, z)
	gizmos.line({from.x, from.y, z}, {to.x, to.y, z})
}

@(comp_on_draw_gizmos={component=FixedJoint2D})
comp_on_draw_gizmos_FixedJoint2D :: proc(j: ^physics2d.FixedJoint2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	other := physics2d.joint_connected_object(j.connected)
	if other == {} do return
	gizmos.with_color(physics2d.COLLIDER_GIZMO_COLOR)
	gizmos.line(engine.transform_world(j.owner).position, engine.transform_world(other).position)
}
