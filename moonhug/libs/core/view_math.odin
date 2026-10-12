package core

// Camera math every view shares: the matrices a frame renders with, a pixel
// unprojected to a world ray, and the TRS matrix. No world access, so the
// editor's viewport and a package's handles use it without the engine.

import "core:math/linalg"

View_Kind :: enum u8 {
	Game,      // a scene Camera component
	SceneView, // the editor's scene view
	Preview,   // thumbnails and inspector previews
}

Render_View :: struct {
	view, proj:    matrix[4, 4]f32,
	view_proj:     matrix[4, 4]f32,
	inv_view_proj: matrix[4, 4]f32,
	cam_pos:       [3]f32, // camera world position (specular shaders, LOD later)
	width, height: f32, // viewport pixels (screen->ray, gizmo sizing)
	layer_mask:    u32,
	kind:          View_Kind,
	camera:        Transform_Handle, // the Camera node a Game view renders for; {} for editor views
}

Ray :: struct {
	origin, direction: [3]f32,
}

render_view_make :: proc(view, proj: matrix[4, 4]f32, width, height: f32, layer_mask: u32, kind: View_Kind = .Game) -> Render_View {
	vp := proj * view
	// Camera world position = translation column of the inverted view matrix
	// — derived here so every caller (game cameras, editor scene view) gets it
	// without extra plumbing.
	inv_view := linalg.inverse(view)
	return Render_View{
		view          = view,
		proj          = proj,
		view_proj     = vp,
		inv_view_proj = linalg.inverse(vp),
		cam_pos       = {inv_view[0, 3], inv_view[1, 3], inv_view[2, 3]},
		width         = width,
		height        = height,
		layer_mask    = layer_mask,
		kind          = kind,
	}
}

// Unprojects a viewport pixel (origin top-left) into a world ray. Replaces
// rl.GetScreenToWorldRay for game code (turret_aim) and feeds scene picking.
render_view_screen_ray :: proc(view: Render_View, px, py: f32) -> Ray {
	ndc_x := 2 * px / max(view.width, 1) - 1
	ndc_y := 1 - 2 * py / max(view.height, 1)
	near4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 0, 1} // z01: near plane at 0
	far4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 1, 1}
	near := near4.xyz / near4.w
	far := far4.xyz / far4.w
	return Ray{origin = near, direction = linalg.normalize(far - near)}
}

trs_matrix :: proc(position: [3]f32, rotation: [4]f32, scale: [3]f32) -> matrix[4, 4]f32 {
	q := quaternion(x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w)
	return linalg.matrix4_from_trs_f32(position, q, scale)
}
