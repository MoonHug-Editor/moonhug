package mhgui

import "core:math"
import "moonhug:engine"

// The graphic that fills a node's rect with a sprite, or with a solid color
// when no sprite is set. The node also needs a CanvasRenderer, which is what
// marks it as drawing; Image only says what.
//
// Image types, Unity's: Simple stretches the sprite over the rect. Sliced
// keeps the sprite's 9-slice borders at their pixel size and stretches the
// edges and the center. Tiled keeps the corners, tiles the edges along their
// length and the center in both directions. Borders come from the sprite
// (the Sprite Editor, or the texture's import settings in Single mode);
// pixels_per_unit_multiplier scales the pixel size the borders and tiles
// draw at (Unity's Pixels Per Unit Multiplier), so 2 halves them.
@(component={menu="UI/Image"})
@(typ_guid={guid = "0a7604a3-0097-4b7d-a565-7ebbdfcaa795"})
Image :: struct {
	using base:      engine.CompData `inspect:"-"`,
	// The fields every graphic shares (color, material, raycast target),
	// serialized under "graphic", drawn flat in the inspector.
	using graphic:   engine.Graphic `inline:""`,
	// guid = the texture, local_id = the slice's persistent id from the
	// texture's import settings, 0 = the whole texture. Hidden from the default
	// inspector — the package's editor wrapper draws the sprite picker.
	sprite:          engine.PPtr `inspect:"-"`,
	image_type:      Image_Type,
	// Keep the sprite's aspect (Simple): the largest aspect-correct rect
	// centered in the node's rect instead of stretching to fill it.
	preserve_aspect: bool,
	fill_center:     bool, // Sliced, Tiled: draw the middle cell
	pixels_per_unit_multiplier: f32,
}

Image_Type :: enum u8 {
	Simple,
	Sliced,
	Tiled,
}

reset_Image :: proc(img: ^Image) {
	img.color = {1, 1, 1, 1}
	img.raycast_target = true
	img.fill_center = true
	img.pixels_per_unit_multiplier = 1
}

// The Image's geometry (engine.Graphic_Desc.populate): one quad for Simple,
// the 9-slice cells for Sliced, the tiles for Tiled.
populate_image :: proc(comp: rawptr, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	img := cast(^Image)comp
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
	}
}

// A hard cap on the tiles one image emits: a tile smaller than a fraction of
// a canvas unit would explode the quad count.
IMAGE_MAX_TILES :: 4096

// The 3x3 cells of a sprite with borders over `rect`, stretched (Sliced) or
// tiled (Tiled: corners fixed, edges tiled along their length, the center in
// both directions, partial tiles cut). Borders and tiles draw at pixel size
// over `ppu_multiplier`. Borders wider than the rect shrink to share it, as
// Unity does. Without borders Sliced is a stretch and Tiled tiles the whole
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
