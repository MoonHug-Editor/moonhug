package mhgui

import "moonhug:engine"

// The graphic that fills a node's rect with a sprite, or with a solid color
// when no sprite is set. The node also needs a CanvasRenderer, which is what
// marks it as drawing; Image only says what.
@(component={menu="UI/Image"})
@(typ_guid={guid = "0a7604a3-0097-4b7d-a565-7ebbdfcaa795"})
Image :: struct {
	using base:      engine.CompData `inspect:"-"`,
	// guid = the texture, local_id = the slice's persistent id from the
	// texture's import settings, 0 = the whole texture. Hidden from the default
	// inspector — the package's editor wrapper draws the sprite picker.
	sprite:          engine.PPtr `inspect:"-"`,
	color:           [4]f32 `decor:color()`,
	// Keep the sprite's aspect: the largest aspect-correct rect centered in
	// the node's rect instead of stretching to fill it.
	preserve_aspect: bool,
}

reset_Image :: proc(img: ^Image) {
	img.color = {1, 1, 1, 1}
}

// What the image draws: the texture, the source pixel rect inside it (x, y,
// w, h, top-left origin) and the texture size. No sprite gives the package's
// white texture, whole. ok=false when the texture is missing or the slice id
// no longer exists.
image_source :: proc(img: ^Image) -> (tex: engine.Asset_GUID, px: [4]f32, tex_size: [2]f32, ok: bool) {
	tex = img.sprite.guid
	if engine.asset_guid_is_empty(tex) {
		// Solid color: the white texture, whole. Its size never matters (the
		// uvs cover it and its aspect is square), so no load.
		return white_texture_guid(), {0, 0, 1, 1}, {1, 1}, true
	}
	t, loaded := engine.texture_load(tex)
	if !loaded do return tex, {}, {}, false
	tex_size = {f32(t.width), f32(t.height)}
	px = {0, 0, tex_size.x, tex_size.y}
	if img.sprite.local_id != 0 {
		s, found := engine.texture_sprite_rect(t, img.sprite.local_id)
		if !found do return tex, {}, tex_size, false
		px = s.rect
	}
	return tex, px, tex_size, true
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
