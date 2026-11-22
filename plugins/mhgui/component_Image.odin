package mhgui

import "core:math"
import "moonhug:packages/engine"

// The graphic that fills a node's rect with a sprite, or with a solid color
// when no sprite is set. The node also needs a CanvasRenderer, which is what
// marks it as drawing; Image only says what.
//
// Image types: Simple stretches the sprite over the rect. Sliced
// keeps the sprite's 9-slice borders at their pixel size and stretches the
// edges and the center. Tiled keeps the corners, tiles the edges along their
// length and the center in both directions. Filled draws a part of the
// sprite, `fill_amount` of it: a bar that grows along an axis, or a sector
// that sweeps round a point, for a health bar or a cooldown (image_filled).
// Borders come from the sprite
// (the Sprite Editor, or the texture's import settings in Single mode);
// pixels_per_unit_multiplier scales the pixel size the borders and tiles
// draw at, so 2 halves them.
@(component={menu="UI/Image"})
@(typ_guid={guid = "0a7604a3-0097-4b7d-a565-7ebbdfcaa795"})
Image :: struct {
	using base:      engine.CompData `inspect:"-"`,
	// The fields every graphic shares (color, material, raycast target),
	// serialized under "graphic", drawn flat in the inspector.
	using graphic:   engine.Graphic `inline:""`,
	// guid = the texture, local_id = the slice's persistent id from the
	// texture's import settings, 0 = the whole texture. Hidden from the default
	// inspector: the package's inspector step draws the sprite picker.
	sprite:          engine.PPtr `inspect:"-"`,
	image_type:      Image_Type,
	// Keep the sprite's aspect (Simple): the largest aspect-correct rect
	// centered in the node's rect instead of stretching to fill it.
	preserve_aspect: bool,
	fill_center:     bool, // Sliced, Tiled: draw the middle cell
	pixels_per_unit_multiplier: f32,
	// Filled.
	fill_method:     Fill_Method `decor:tooltip(desc="Filled: how the part that shows grows. Along an axis, or round a corner (90), the middle of an edge (180) or the centre (360).")`,
	fill_origin:     Fill_Origin `decor:tooltip(desc="Filled: where the fill starts. Horizontal: Left or Right. Vertical: Bottom or Top. Radial_180: the edge the sweep turns on. Radial_360: the edge the sweep starts at. Radial_90: the corner, Bottom is bottom left, Right bottom right, Top top right, Left top left.")`,
	fill_amount:     f32 `decor:range(0, 1) decor:tooltip(desc="Filled: how much of the image shows, 0 to 1.")`,
	fill_clockwise:  bool `decor:tooltip(desc="Filled, radial: the sweep turns clockwise.")`,
	alpha_hit_threshold: f32 `decor:range(0, 1) decor:tooltip(desc="The pointer hits the image only where the sprite's alpha is at least this. 0 hits the whole rect. Simple and Filled images.")`,
}

Image_Type :: enum u8 {
	Simple,
	Sliced,
	Tiled,
	Filled,
}

Fill_Method :: enum u8 {
	Horizontal,
	Vertical,
	Radial_90,
	Radial_180,
	Radial_360,
}

Fill_Origin :: enum u8 {
	Bottom,
	Right,
	Top,
	Left,
}

type_reset_Image :: proc(img: ^Image) {
	img.color = {1, 1, 1, 1}
	img.raycast_target = true
	img.fill_center = true
	img.pixels_per_unit_multiplier = 1
	img.fill_amount = 1
	img.fill_clockwise = true
}

// The Image's geometry: one quad for Simple, the 9-slice cells for Sliced,
// the tiles for Tiled.
@(canvas_graphic)
canvas_populate_Image :: proc(img: ^Image, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	tex, px, tex_size, border, ok := image_source(img)
	if !ok do return
	switch img.image_type {
	case .Simple:
		fit := image_fit(rect, {px.z, px.w}, img.preserve_aspect)
		append(out, engine.Graphic_Quad{pos = fit.pos, size = fit.size, uvs = image_uvs(tex_size, px), texture = tex})
	case .Sliced:
		image_sliced(out, tex, tex_size, px, border, rect, img.fill_center, img.pixels_per_unit_multiplier, tiled = false)
	case .Tiled:
		image_sliced(out, tex, tex_size, px, border, rect, img.fill_center, img.pixels_per_unit_multiplier, tiled = true)
	case .Filled:
		fit := image_fit(rect, {px.z, px.w}, img.preserve_aspect)
		image_filled(out, tex, image_uvs(tex_size, px), fit, img.fill_method, img.fill_origin, img.fill_amount, img.fill_clockwise)
	}
}

// The part of an image a fill shows: `amount` (0 to 1) of `rect`, the uvs
// (bl, br, tr, tl) cut along with it.
// - Horizontal and Vertical: a bar from the origin's side.
// - Radial_360: a sector round the centre that starts at the origin's edge.
// - Radial_180: a sector round the middle of the origin's edge.
// - Radial_90: a sector round a corner: Bottom is the bottom left one, Right
//   the bottom right, Top the top right, Left the top left.
// A sector is a fan of triangles from its point.
image_filled :: proc(out: ^[dynamic]engine.Graphic_Quad, tex: engine.Asset_GUID, uvs: [4][2]f32, rect: engine.Rect, method: Fill_Method, origin: Fill_Origin, amount: f32, clockwise: bool) {
	amount := clamp(amount, 0, 1)
	if amount <= 0 || rect.size.x <= 0 || rect.size.y <= 0 do return
	lo, hi := rect.pos, rect.pos + rect.size
	// The uv of a point of the rect.
	uv_at :: proc(uvs: [4][2]f32, rect: engine.Rect, p: [2]f32) -> [2]f32 {
		t := (p - rect.pos) / rect.size
		bottom := uvs[0] + (uvs[1] - uvs[0]) * t.x
		top := uvs[3] + (uvs[2] - uvs[3]) * t.x
		return bottom + (top - bottom) * t.y
	}
	bar :: proc(out: ^[dynamic]engine.Graphic_Quad, tex: engine.Asset_GUID, uvs: [4][2]f32, rect: engine.Rect, a, b: [2]f32) {
		corners := [4][2]f32{{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, b.y}}
		q := engine.Graphic_Quad{pos = a, size = b - a, texture = tex}
		for c, k in corners do q.uvs[k] = uv_at(uvs, rect, c)
		append(out, q)
	}
	switch method {
	case .Horizontal:
		w := rect.size.x * amount
		if origin == .Right do bar(out, tex, uvs, rect, {hi.x - w, lo.y}, hi)
		else do bar(out, tex, uvs, rect, lo, {lo.x + w, hi.y})
		return
	case .Vertical:
		h := rect.size.y * amount
		if origin == .Top do bar(out, tex, uvs, rect, {lo.x, hi.y - h}, hi)
		else do bar(out, tex, uvs, rect, lo, {hi.x, lo.y + h})
		return
	case .Radial_90, .Radial_180, .Radial_360:
	}

	// The sector's point, and the angles the whole of it runs between,
	// counter-clockwise from +x.
	mid := (lo + hi) * 0.5
	pivot: [2]f32
	from, range: f32
	#partial switch method {
	case .Radial_360:
		pivot = mid
		range = math.TAU
		switch origin {
		case .Bottom: from = -math.PI / 2
		case .Right:  from = 0
		case .Top:    from = math.PI / 2
		case .Left:   from = math.PI
		}
		// The whole of it is the rect.
		if amount >= 1 {
			bar(out, tex, uvs, rect, lo, hi)
			return
		}
	case .Radial_180:
		range = math.PI
		switch origin {
		case .Bottom: pivot, from = {mid.x, lo.y}, 0
		case .Right:  pivot, from = {hi.x, mid.y}, math.PI / 2
		case .Top:    pivot, from = {mid.x, hi.y}, math.PI
		case .Left:   pivot, from = {lo.x, mid.y}, -math.PI / 2
		}
	case .Radial_90:
		range = math.PI / 2
		switch origin {
		case .Bottom: pivot, from = lo, 0
		case .Right:  pivot, from = {hi.x, lo.y}, math.PI / 2
		case .Top:    pivot, from = hi, math.PI
		case .Left:   pivot, from = {lo.x, hi.y}, -math.PI / 2
		}
	}
	// The angles that show. A full circle starts and ends at `from`. A half
	// or a quarter grows from one of its two ends.
	a0, a1: f32
	if method == .Radial_360 {
		if clockwise do a0, a1 = from - range * amount, from
		else do a0, a1 = from, from + range * amount
	} else if clockwise {
		a0, a1 = from + range * (1 - amount), from + range
	} else {
		a0, a1 = from, from + range * amount
	}

	// Where a ray from the pivot leaves the rect.
	leave :: proc(pivot, lo, hi: [2]f32, angle: f32) -> [2]f32 {
		d := [2]f32{math.cos(angle), math.sin(angle)}
		t := max(f32)
		if d.x > 1e-6 do t = min(t, (hi.x - pivot.x) / d.x)
		if d.x < -1e-6 do t = min(t, (lo.x - pivot.x) / d.x)
		if d.y > 1e-6 do t = min(t, (hi.y - pivot.y) / d.y)
		if d.y < -1e-6 do t = min(t, (lo.y - pivot.y) / d.y)
		if t == max(f32) do t = 0
		return {clamp(pivot.x + d.x * t, lo.x, hi.x), clamp(pivot.y + d.y * t, lo.y, hi.y)}
	}
	// The rim: where the first angle leaves the rect, the rect's corners
	// between the two angles in turn, where the last angle leaves it.
	Rim :: struct {
		angle: f32,
		point: [2]f32,
	}
	rim: [6]Rim
	count := 0
	rim[count] = {a0, leave(pivot, lo, hi, a0)}
	count += 1
	for c in ([4][2]f32{lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}) {
		to := c - pivot
		if abs(to.x) < 1e-5 && abs(to.y) < 1e-5 do continue
		angle := math.atan2(to.y, to.x)
		// Brought to the turn the sector is in.
		angle += math.TAU * math.ceil((a0 - angle) / math.TAU)
		if angle <= a0 + 1e-4 || angle >= a1 - 1e-4 do continue
		// Kept in order: at most four, an insertion does.
		at := count
		for at > 1 && rim[at - 1].angle > angle {
			rim[at] = rim[at - 1]
			at -= 1
		}
		rim[at] = {angle, c}
		count += 1
	}
	rim[count] = {a1, leave(pivot, lo, hi, a1)}
	count += 1
	for k in 0 ..< count - 1 {
		a, b := rim[k].point, rim[k + 1].point
		engine.graphic_triangle(out, {pivot, a, b}, {uv_at(uvs, rect, pivot), uv_at(uvs, rect, a), uv_at(uvs, rect, b)}, tex)
	}
}

// A hard cap on the tiles one image emits: a tile smaller than a fraction of
// a canvas unit would explode the quad count.
IMAGE_MAX_TILES :: 4096

// The 3x3 cells of a sprite with borders over `rect`, stretched (Sliced) or
// tiled (Tiled: corners fixed, edges tiled along their length, the center in
// both directions, partial tiles cut). Borders and tiles draw at pixel size
// over `ppu_multiplier`. Borders wider than the rect shrink to share it. Without borders Sliced is a stretch and Tiled tiles the whole
// sprite.
image_sliced :: proc(out: ^[dynamic]engine.Graphic_Quad, tex: engine.Asset_GUID, tex_size: [2]f32, px: [4]f32, border: [4]f32, rect: engine.Rect, fill_center: bool, ppu_multiplier: f32, tiled: bool) {
	m := 1 / ppu_multiplier if ppu_multiplier > 0 else 1 // 0 (a component saved before the field existed) means 1
	// Border widths in canvas units, shrunk when they cannot both fit.
	l, b, r, t := border.x * m, border.y * m, border.z * m, border.w * m
	if l + r > rect.size.x && l + r > 0 {
		k := rect.size.x / (l + r)
		l *= k
		r *= k
	}
	if b + t > rect.size.y && b + t > 0 {
		k := rect.size.y / (b + t)
		b *= k
		t *= k
	}
	// Canvas x cuts left to right, y cuts bottom to top; pixel cuts in the
	// sprite: x left to right, y TOP to bottom (rows).
	xs := [4]f32{rect.pos.x, rect.pos.x + l, rect.pos.x + rect.size.x - r, rect.pos.x + rect.size.x}
	ys := [4]f32{rect.pos.y, rect.pos.y + b, rect.pos.y + rect.size.y - t, rect.pos.y + rect.size.y}
	pxs := [4]f32{px.x, px.x + border.x, px.x + px.z - border.z, px.x + px.z}
	pys := [4]f32{px.y + px.w, px.y + px.w - border.y, px.y + border.w, px.y} // bottom to top, like ys

	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			if row == 1 && col == 1 && !fill_center do continue
			cell := engine.Rect{pos = {xs[col], ys[row]}, size = {xs[col + 1] - xs[col], ys[row + 1] - ys[row]}}
			if cell.size.x <= 0 || cell.size.y <= 0 do continue
			// The cell's source pixels: x0, y_top, w, h in the sprite.
			src := [4]f32{pxs[col], pys[row + 1], pxs[col + 1] - pxs[col], pys[row] - pys[row + 1]}
			if src.z <= 0 || src.w <= 0 do continue
			// Tiles repeat along the axes the cell stretches on: the center
			// both ways, edges along their length, corners never.
			tile_x := tiled && col == 1
			tile_y := tiled && row == 1
			_image_cell(out, tex, tex_size, cell, src, tile_x, tile_y, m)
		}
	}
}

// One cell: a single quad, or a grid of tiles at the source's pixel size
// times `m`, the last row and column cut to the cell with their uvs cut the
// same way.
@(private = "file")
_image_cell :: proc(out: ^[dynamic]engine.Graphic_Quad, tex: engine.Asset_GUID, tex_size: [2]f32, cell: engine.Rect, src: [4]f32, tile_x, tile_y: bool, m: f32) {
	tile_x, tile_y := tile_x, tile_y
	tile := [2]f32{src.z * m, src.w * m}
	nx := 1
	ny := 1
	if tile_x && tile.x > 0 do nx = int(math.ceil(cell.size.x / tile.x - 1e-4))
	if tile_y && tile.y > 0 do ny = int(math.ceil(cell.size.y / tile.y - 1e-4))
	if nx * ny > IMAGE_MAX_TILES {
		nx, ny = 1, 1 // too fine to tile: stretch
		tile_x, tile_y = false, false
	}
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			q := cell
			s := src
			if tile_x {
				q.pos.x = cell.pos.x + f32(i) * tile.x
				q.size.x = min(tile.x, cell.pos.x + cell.size.x - q.pos.x)
				s.z = src.z * (q.size.x / tile.x)
			}
			if tile_y {
				q.pos.y = cell.pos.y + f32(j) * tile.y
				q.size.y = min(tile.y, cell.pos.y + cell.size.y - q.pos.y)
				// Tiles grow upward; the sprite's rows grow downward, so a cut
				// tile keeps the source's bottom rows.
				cut := src.w * (q.size.y / tile.y)
				s.y = src.y + src.w - cut
				s.w = cut
			}
			append(out, engine.Graphic_Quad{pos = q.pos, size = q.size, uvs = image_uvs(tex_size, s), texture = tex})
		}
	}
}

// What the image draws: the texture, the source pixel rect inside it (x, y,
// w, h, top-left origin), the texture size and the sprite's 9-slice borders
// (left, bottom, right, top, pixels). No sprite gives the package's white
// texture, whole. ok=false when the texture is missing or the slice id no
// longer exists.
image_source :: proc(img: ^Image) -> (tex: engine.Asset_GUID, px: [4]f32, tex_size: [2]f32, border: [4]f32, ok: bool) {
	tex = img.sprite.guid
	if engine.asset_guid_is_empty(tex) {
		// Solid color: the white texture, whole. Its size never matters (the
		// uvs cover it and its aspect is square), so no load.
		return white_texture_guid(), {0, 0, 1, 1}, {1, 1}, {}, true
	}
	t, loaded := engine.texture_load(tex)
	if !loaded do return tex, {}, {}, {}, false
	tex_size = {f32(t.width), f32(t.height)}
	px = {0, 0, tex_size.x, tex_size.y}
	border = t.border
	if img.sprite.local_id != 0 {
		s, found := engine.texture_sprite_rect(t, img.sprite.local_id)
		if !found do return tex, {}, tex_size, {}, false
		px = s.rect
		border = s.border
	}
	return tex, px, tex_size, border, true
}

// The rect the image fills: `rect` itself, or with preserve_aspect the
// largest sub-rect with the sprite's aspect, centered.
image_fit :: proc(rect: engine.Rect, sprite_size: [2]f32, preserve_aspect: bool) -> engine.Rect {
	if !preserve_aspect || sprite_size.x <= 0 || sprite_size.y <= 0 || rect.size.x <= 0 || rect.size.y <= 0 {
		return rect
	}
	scale := min(rect.size.x / sprite_size.x, rect.size.y / sprite_size.y)
	size := sprite_size * scale
	return engine.Rect{pos = rect.pos + (rect.size - size) * 0.5, size = size}
}

// Normalized uvs, bl br tr tl, of a pixel rect (top-left origin, y down)
// inside a texture. uv origin is top-left too, so the rect's top edge is
// the smaller v.
image_uvs :: proc(tex_size: [2]f32, px: [4]f32) -> [4][2]f32 {
	u0 := px.x / tex_size.x
	u1 := (px.x + px.z) / tex_size.x
	v_top := px.y / tex_size.y
	v_bottom := (px.y + px.w) / tex_size.y
	return {{u0, v_bottom}, {u1, v_bottom}, {u1, v_top}, {u0, v_top}}
}

// The pointer hits an Image with alpha_hit_threshold over 0 only where its
// sprite's alpha reaches it: the clear corners of a round icon take no
// pointer. A Filled image is also missed in the part that does not show.
// Sliced and Tiled images, and an image whose texture cannot be read, are
// hit anywhere in the rect.
@(canvas_hit)
canvas_hit_Image :: proc(img: ^Image, rect: engine.Rect, point: [2]f32) -> bool {
	if img.alpha_hit_threshold <= 0 || engine.asset_guid_is_empty(img.sprite.guid) do return true
	if img.image_type != .Simple && img.image_type != .Filled do return true
	tex, px, tex_size, _, ok := image_source(img)
	if !ok do return true
	fit := image_fit(rect, {px.z, px.w}, img.preserve_aspect)
	if fit.size.x <= 0 || fit.size.y <= 0 do return false
	t := (point - fit.pos) / fit.size
	if t.x < 0 || t.y < 0 || t.x > 1 || t.y > 1 do return false
	if img.image_type == .Filled {
		// Inside one of the triangles and bars the fill draws.
		quads := make([dynamic]engine.Graphic_Quad, context.temp_allocator)
		image_filled(&quads, tex, engine.QUAD_UVS_FULL, fit, img.fill_method, img.fill_origin, img.fill_amount, img.fill_clockwise)
		shown := false
		for q in quads {
			c := engine.graphic_quad_points(q)
			side := [4]f32{}
			for k in 0 ..< 4 {
				a, b := c[k], c[(k + 1) % 4]
				side[k] = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
			}
			if (side[0] >= 0 && side[1] >= 0 && side[2] >= 0 && side[3] >= 0) || (side[0] <= 0 && side[1] <= 0 && side[2] <= 0 && side[3] <= 0) {
				shown = true
				break
			}
		}
		if !shown do return false
	}
	// The sprite's pixel under the point: its rows run down.
	uv := [2]f32{(px.x + t.x * px.z) / tex_size.x, (px.y + (1 - t.y) * px.w) / tex_size.y}
	alpha, known := engine.texture_alpha(tex, uv)
	return !known || alpha >= img.alpha_hit_threshold
}
