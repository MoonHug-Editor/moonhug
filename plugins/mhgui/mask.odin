package mhgui

import "base:runtime"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"

// Clips the nodes under it to its rect: what lies outside is not drawn and
// takes no pointer. A scrolling list's viewport is one. The node's own
// graphic is not clipped.
//
// - The clip follows the node: turned, scaled, or on a canvas in the world
//   seen at an angle.
// - Each corner of the rect has its own radius, and the edge can fade.
// - Masks nest: a node is cut by every mask above it, each with its own
//   corners and edge, up to gfx.CLIP_MAX of them.
// - With a sprite the mask also multiplies by the sprite's alpha, the sprite
//   stretched over the rect: any outline an image has, and a fade where the
//   image fades. Of the masks above a node the nearest one with a sprite
//   uses it, the ones above that clip by their rect. The pointer goes by
//   the rect and its corners, not by the sprite.
// - The shader of a clipped quad does the clipping (libs/gfx/shaders/
//   ui_clip.glsl). The built-in unlit shader does, and every shader the
//   importer compiles does when the project's UiMask setting is Auto Inject
//   (ui_mask_settings.odin).
@(component={menu="UI/UiMask", icon="CROP"})
@(typ_guid={guid = "0907bcc0-c7db-4651-8e5d-826ae1bd8806"})
UiMask :: struct {
	using base:    engine.CompData `inspect:"-"`,
	// Top left, top right, bottom right, bottom left.
	corner_radius: [4]f32 `decor:min(0) decor:tooltip(desc="The radius of each corner, in canvas units: top left, top right, bottom right, bottom left. A radius is cut to half the shorter side, so a large one on a square makes a circle.")`,
	softness:      f32 `decor:min(0) decor:tooltip(desc="The width the edge fades over, inward, in canvas units. 0 is a crisp edge.")`,
	// Drawn by the inspector's sprite picker (the field itself is inspect:"-").
	sprite:        engine.PPtr `inspect:"-"`,
}

// The texture of a mask's sprite and the sprite's part of it (x, y, width,
// height in 0..1 from the top left). False with no sprite, or one that is
// missing.
mask_sprite :: proc(mask: ^UiMask) -> (tex: ^gfx.Texture, uv: [4]f32, ok: bool) {
	t: ^engine.Texture2D
	t, uv = mask_sprite_uv(mask) or_return
	return t.gfx, uv, t.gfx != nil
}

// The texture of a mask's sprite and the sprite's part of it.
mask_sprite_uv :: proc(mask: ^UiMask) -> (t: ^engine.Texture2D, uv: [4]f32, ok: bool) {
	if engine.asset_guid_is_empty(mask.sprite.guid) do return
	t = engine.texture_load(mask.sprite.guid) or_return
	if t.width <= 0 || t.height <= 0 do return
	px := [4]f32{0, 0, f32(t.width), f32(t.height)}
	if mask.sprite.local_id != 0 {
		s := engine.texture_sprite_rect(t, mask.sprite.local_id) or_return
		px = s.rect
	}
	w, h := f32(t.width), f32(t.height)
	return t, {px.x / w, px.y / h, px.z / w, px.w / h}, true
}

// The nearest enabled UiMask above the node, {} for none. The node's own
// mask does not count: it clips what is under it.
node_mask :: proc(tH: engine.Transform_Handle) -> engine.Transform_Handle {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	for n := 0; t != nil && n < 4096; n += 1 {
		parent := engine.Transform_Handle(t.parent.handle)
		if parent == {} do return {}
		if _, mask := engine.transform_get_comp(parent, UiMask); mask != nil && mask.enabled do return parent
		t = engine.pool_get(&w.transforms, engine.Handle(parent))
	}
	return {}
}

// A canvas point in a mask node's own space, from its rect's centre.
@(private = "file")
_mask_local :: proc(mask: engine.Node_Rect, canvas_point: [3]f32) -> [2]f32 {
	local := (linalg.inverse(mask.xform) * [4]f32{canvas_point.x, canvas_point.y, canvas_point.z, 1}).xy
	return local - (mask.rect.pos + mask.rect.size * 0.5)
}

// The signed distance from `p` (from the rect's centre) to the mask's
// outline with its round corners: negative inside. The shaders' ui_clip
// computes the same.
mask_distance :: proc(m: ^UiMask, half: [2]f32, p: [2]f32) -> f32 {
	r: f32
	switch {
	case p.x > 0 && p.y > 0:  r = m.corner_radius[1]
	case p.x > 0:             r = m.corner_radius[2]
	case p.y > 0:             r = m.corner_radius[0]
	case:                     r = m.corner_radius[3]
	}
	r = clamp(r, 0, min(half.x, half.y))
	q := [2]f32{abs(p.x) - half.x + r, abs(p.y) - half.y + r}
	outside := [2]f32{max(q.x, 0), max(q.y, 0)}
	return min(max(q.x, q.y), 0) + linalg.length(outside) - r
}

// Whether a canvas point is inside a mask's outline, round corners included.
mask_contains :: proc(mask_tH: engine.Transform_Handle, node: engine.Node_Rect, canvas_point: [2]f32) -> bool {
	_, mask := engine.transform_get_comp(mask_tH, UiMask)
	if mask == nil do return true
	half := node.rect.size * 0.5
	if half.x <= 0 || half.y <= 0 do return false
	local := _mask_local(node, {canvas_point.x, canvas_point.y, 0})
	if mask_distance(mask, half, local) > 0 do return false
	// A sprite's clear part hides what is under the mask: no pointer there.
	if !engine.asset_guid_is_empty(mask.sprite.guid) {
		if _, uv, has := mask_sprite_uv(mask); has {
			unit := [2]f32{local.x / (2 * half.x) + 0.5, 0.5 - local.y / (2 * half.y)}
			if alpha, known := engine.texture_alpha(mask.sprite.guid, uv.xy + unit * uv.zw); known && alpha < MASK_HIT_ALPHA do return false
		}
	}
	return true
}

// A sprite mask takes the pointer where its sprite's alpha is at least this.
MASK_HIT_ALPHA :: f32(0.1)

// The mask as gfx clips to it: the map from a target pixel to the mask's own
// space, found from where its rect's four corners are drawn, with its shape.
// False when a corner is behind the camera or the rect has no area.
mask_clip :: proc(c: engine.Canvas_Pixels, mask_tH: engine.Transform_Handle, node: engine.Node_Rect) -> (clip: gfx.Clip_Mask, ok: bool) {
	_, mask := engine.transform_get_comp(mask_tH, UiMask)
	if mask == nil do return
	half := node.rect.size * 0.5
	if half.x <= 0 || half.y <= 0 do return
	// The rect's corners (bl, br, tr, tl): where they are drawn, and where
	// they are in the mask's space.
	local := [4][2]f32{{-half.x, -half.y}, {half.x, -half.y}, {half.x, half.y}, {-half.x, half.y}}
	pixels: [4][2]f32
	for corner, k in engine.rect_corners(node.rect, node.xform) {
		pixels[k] = engine.canvas_point_pixel(c, corner) or_return
	}
	h := _homography(pixels, local) or_return
	clip.to = {{h[0], h[1], h[2], 0}, {h[3], h[4], h[5], 0}, {h[6], h[7], 1, 0}}
	clip.shape = {half.x, half.y, max(mask.softness, 0), 0}
	clip.radii = mask.corner_radius
	if tex, uv, has := mask_sprite(mask); has do clip.tex, clip.uv = tex, uv
	return clip, true
}

// The map that takes each `from` point to its `to` point, as (x, y) =
// (h0 u + h1 v + h2, h3 u + h4 v + h5) / (h6 u + h7 v + 1): what a flat
// rect seen in perspective needs. Solved in doubles. False when the points
// do not span an area.
@(private = "file")
_homography :: proc(from, to: [4][2]f32) -> (h: [8]f32, ok: bool) {
	a: [8][9]f64
	for k in 0 ..< 4 {
		u, v := f64(from[k].x), f64(from[k].y)
		x, y := f64(to[k].x), f64(to[k].y)
		a[k * 2] = {u, v, 1, 0, 0, 0, -u * x, -v * x, x}
		a[k * 2 + 1] = {0, 0, 0, u, v, 1, -u * y, -v * y, y}
	}
	// Gauss-Jordan with the largest pivot of each column.
	for col in 0 ..< 8 {
		pivot := col
		for row in col + 1 ..< 8 do if abs(a[row][col]) > abs(a[pivot][col]) do pivot = row
		if abs(a[pivot][col]) < 1e-12 do return {}, false
		a[col], a[pivot] = a[pivot], a[col]
		for row in 0 ..< 8 {
			if row == col do continue
			f := a[row][col] / a[col][col]
			if f == 0 do continue
			for k in col ..< 9 do a[row][k] -= f * a[col][k]
		}
	}
	for k in 0 ..< 8 do h[k] = f32(a[k][8] / a[k][k])
	return h, true
}

// The masks a node's quads are clipped to, the nearest first, at most
// gfx.CLIP_MAX. `nodes` are the canvas's resolved rects. Allocated with the
// temp allocator. Empty with no mask above the node.
mask_stack :: proc(c: engine.Canvas_Pixels, tH: engine.Transform_Handle, nodes: []engine.Node_Rect) -> []gfx.Clip_Mask {
	stack := make([dynamic]gfx.Clip_Mask, context.temp_allocator)
	for mask_tH := node_mask(tH); mask_tH != {} && len(stack) < gfx.CLIP_MAX; mask_tH = node_mask(mask_tH) {
		for m in nodes do if m.tH == mask_tH {
			if clip, ok := mask_clip(c, mask_tH, m); ok do append(&stack, clip)
			break
		}
	}
	return stack[:]
}


// The engine's collector asks these which masks a node is under
// (engine.Canvas_Clip_Provider).
@(init)
_mask_install :: proc "contextless" () {
	context = runtime.default_context()
	engine.canvas_clip_install({
		any     = proc() -> bool { return ui_masks(engine.ctx_world()).count > 0 },
		nearest = node_mask,
		stack   = mask_stack,
	})
}
