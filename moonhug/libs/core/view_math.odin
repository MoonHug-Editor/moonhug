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

// How a view shades what it draws. Shaded is the game's look, the rest are
// the scene view's debug modes, applied by the engine's render execute.
View_Mode :: enum u8 {
	Shaded,
	Wireframe, // meshes as lines, unlit
	Unlit,     // every material through the unlit shader, textures kept
	Normals,   // world-space normals as color
	Overdraw,  // every surface a faint additive layer, no depth test: brighter = more overdraw
}

Render_View :: struct {
	view, proj:    matrix[4, 4]f32,
	view_proj:     matrix[4, 4]f32,
	inv_view_proj: matrix[4, 4]f32,
	cam_pos:       [3]f32, // camera world position (specular shaders, LOD later)
	width, height: f32, // viewport pixels (screen->ray, gizmo sizing)
	layer_mask:    u32,
	kind:          View_Kind,
	mode:          View_Mode,
	camera:        Transform_Handle, // the Camera node a Game view renders for; {} for editor views
	// The view's clip planes in world space (render_view_make). With `cull`
	// on, collectors drop what lies wholly outside them. Off by default: a
	// probe view built from identity matrices (the shadow pass collecting
	// every caster) is not a camera, and nothing it would drop is invisible.
	frustum:       Frustum,
	cull:          bool,
	// With mode Normals: the normals as they are (xyz, for a shader that
	// reads them) instead of encoded as colour (0.5 + 0.5 n, to look at).
	normals_raw:   bool,
}

// Six clip planes, each (normal, d) with dot(normal, p) + d >= 0 inside:
// left, right, bottom, top, near, far.
Frustum :: [6][4]f32

// The world-space planes of a view-projection matrix. The near plane is the
// -1 <= z/w one: exact for such projections, and for the engine's 0 <= z/w
// projections it keeps a little extra in front of the near plane, never
// less than the view sees.
frustum_from_view_proj :: proc(vp: matrix[4, 4]f32) -> (f: Frustum) {
	row :: proc(m: matrix[4, 4]f32, i: int) -> [4]f32 {
		return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}
	}
	r0, r1, r2, r3 := row(vp, 0), row(vp, 1), row(vp, 2), row(vp, 3)
	f = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 + r2, r3 - r2}
	for &plane in f {
		if l := linalg.length(plane.xyz); l > 0 do plane /= l
	}
	return
}

// False when the box (world-space min and max corners) lies wholly outside
// one of the planes. A box crossing the frustum's corner region outside two
// planes at once still passes: conservative, never wrong.
frustum_intersects_aabb :: proc(f: Frustum, lo, hi: [3]f32) -> bool {
	c := (lo + hi) * 0.5
	e := (hi - lo) * 0.5
	for plane in f {
		n := plane.xyz
		if linalg.dot(n, c) + plane.w + linalg.dot(linalg.abs(n), e) < 0 do return false
	}
	return true
}

// The world-space box around a local box (min and max corners) moved by
// `m`: the transformed centre plus the extents through |m|.
aabb_transform :: proc(lo, hi: [3]f32, m: matrix[4, 4]f32) -> (world_lo, world_hi: [3]f32) {
	c := (lo + hi) * 0.5
	e := (hi - lo) * 0.5
	wc := (m * [4]f32{c.x, c.y, c.z, 1}).xyz
	we: [3]f32
	for i in 0 ..< 3 {
		we[i] = abs(m[i, 0]) * e.x + abs(m[i, 1]) * e.y + abs(m[i, 2]) * e.z
	}
	return wc - we, wc + we
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
		frustum       = frustum_from_view_proj(vp),
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
