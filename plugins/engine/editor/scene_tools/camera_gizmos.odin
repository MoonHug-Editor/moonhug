package scene_tools

// Camera frustum gizmo: the selected camera draws its view frustum as a wire
// frustum (near rect, far rect, connecting edges), a box for an orthographic
// camera. Aspect comes from the Game window's render target so the wires show
// exactly what the Game window sees. Runs through @(comp_on_draw_gizmos) for
// cameras in the selection, drawn with libs/gizmos. Every camera also gets a
// scene icon.

import "moonhug:packages/engine"
import "moonhug:libs/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/session"

CAMERA_GIZMO_COLOR :: [4]f32{0.9, 0.9, 0.9, 0.9}

// Scene icon: a camera body and its lens.
@(private = "file")
_icon_camera :: proc() {
	gizmos.wire_rect({-0.2, 0, 0}, {0.9, 0.6})
	gizmos.wire_triangle({0.25, 0, 0}, {0.7, 0.3, 0}, {0.7, -0.3, 0})
}

@(comp_on_draw_gizmos={component=Camera})
comp_on_draw_gizmos_Camera :: proc(cam: ^engine.Camera, ctx: handles.Gizmo_Context) {
	handles.icon(engine.transform_world_position(engine.Transform_Handle(cam.owner)), engine.Transform_Handle(cam.owner), _icon_camera)
	if .In_Selection not_in ctx.state do return
	tw := engine.transform_world(engine.Transform_Handle(cam.owner))
	rot := engine.quat_to_matrix3(tw.rotation)
	right := [3]f32{rot[0, 0], rot[1, 0], rot[2, 0]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}

	aspect := f32(16.0 / 9.0)
	if a, ok := session.game_aspect(); ok do aspect = a

	rect :: proc(cam: ^engine.Camera, origin: [3]f32, right, up, forward: [3]f32, d, aspect: f32) -> [4][3]f32 {
		hh := engine.camera_half_height_at(cam, d)
		hw := hh * aspect
		c := origin + forward * d
		return {
			c - right * hw - up * hh,
			c + right * hw - up * hh,
			c + right * hw + up * hh,
			c - right * hw + up * hh,
		}
	}
	near := rect(cam, tw.position, right, up, forward, max(cam.near_clip, 0.01), aspect)
	far := rect(cam, tw.position, right, up, forward, max(cam.far_clip, cam.near_clip), aspect)

	gizmos.with_color(CAMERA_GIZMO_COLOR)
	gizmos.wire_frustum(near, far)
}
