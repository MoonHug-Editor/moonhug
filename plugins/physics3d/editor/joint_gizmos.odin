package physics3d_editor

// Joint gizmos in the Scene window, for selected objects: a hinge's pivot and
// axis, a distance joint's two anchors and the line between them, a fixed
// joint's line to its other body. Drawn where the anchors are now.

import "moonhug:packages/engine"
import "moonhug:libs/gizmos"
import "moonhug:editor/handles"
import physics3d "moonhug:packages/physics3d"

@(comp_on_draw_gizmos={component=HingeJoint})
comp_on_draw_gizmos_HingeJoint :: proc(j: ^physics3d.HingeJoint, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(physics3d.COLLIDER_GIZMO_COLOR)
	pivot := physics3d.joint_anchor_world(j.owner, j.anchor)
	axis := physics3d.joint_axis_world(j.owner, j.axis)
	r := gizmos.helper_pixel(pivot, 10)
	gizmos.wire_circle(pivot, axis, r)
	gizmos.line_arrow(pivot - axis * r * 2, pivot + axis * r * 4)
	if other := physics3d.joint_connected_object(j.connected); other != {} {
		gizmos.line(pivot, engine.transform_world(other).position)
	}
}

@(comp_on_draw_gizmos={component=DistanceJoint})
comp_on_draw_gizmos_DistanceJoint :: proc(j: ^physics3d.DistanceJoint, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(physics3d.COLLIDER_GIZMO_COLOR)
	from := physics3d.joint_anchor_world(j.owner, j.anchor)
	to := j.connected_anchor
	if other := physics3d.joint_connected_object(j.connected); other != {} do to = physics3d.joint_anchor_world(other, j.connected_anchor)
	gizmos.line_cross(from, gizmos.helper_pixel(from, 8))
	gizmos.line_cross(to, gizmos.helper_pixel(to, 8))
	gizmos.line(from, to)
}

@(comp_on_draw_gizmos={component=FixedJoint})
comp_on_draw_gizmos_FixedJoint :: proc(j: ^physics3d.FixedJoint, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	other := physics3d.joint_connected_object(j.connected)
	if other == {} do return
	gizmos.with_color(physics3d.COLLIDER_GIZMO_COLOR)
	gizmos.line(engine.transform_world(j.owner).position, engine.transform_world(other).position)
}
