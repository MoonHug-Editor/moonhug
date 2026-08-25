package editor

// Camera frustum gizmo (Unity's): the selected camera draws its view frustum
// as wireframe lines — near rect, far rect, connecting edges. Aspect comes
// from the game view's render target so the wires show exactly what the game
// view sees. Runs through the @(on_draw_gizmos_selected) hook inside the
// scene view's pass (world-space view_proj is set).

import "core:math"
import "moonhug:engine"
import gfx "../engine/gfx"

CAMERA_GIZMO_COLOR :: [4]f32{0.9, 0.9, 0.9, 0.9}

@(on_draw_gizmos_selected={component=Camera})
camera_gizmos :: proc(cam: ^engine.Camera) {
	tw := engine.transform_world(engine.Transform_Handle(cam.owner))
	rot := engine.quat_to_matrix3(tw.rotation)
	right := [3]f32{rot[0, 0], rot[1, 0], rot[2, 0]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}

	aspect := f32(16.0 / 9.0)
	if game_rt != nil && game_rt.height > 0 {
		aspect = f32(game_rt.width) / f32(game_rt.height)
	}
	tan_half := math.tan(math.to_radians(cam.fov) * 0.5)

	rect :: proc(origin: [3]f32, right, up, forward: [3]f32, d, tan_half, aspect: f32) -> [4][3]f32 {
		hh := d * tan_half
		hw := hh * aspect
		c := origin + forward * d
		return {
			c - right * hw - up * hh,
			c + right * hw - up * hh,
			c + right * hw + up * hh,
			c - right * hw + up * hh,
		}
	}
	near := rect(tw.position, right, up, forward, max(cam.near_clip, 0.01), tan_half, aspect)
	far := rect(tw.position, right, up, forward, max(cam.far_clip, cam.near_clip), tan_half, aspect)

	for i in 0 ..< 4 {
		j := (i + 1) % 4
		gfx.draw_line(near[i], near[j], CAMERA_GIZMO_COLOR)
		gfx.draw_line(far[i], far[j], CAMERA_GIZMO_COLOR)
		gfx.draw_line(near[i], far[i], CAMERA_GIZMO_COLOR)
	}
}
