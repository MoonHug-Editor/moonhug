package mhgui

// RawImage: a graphic that draws a texture, whole or a part of it given in
// uv, stretched over the node's rect. The node also needs a CanvasRenderer.
//
// An Image draws a sprite: a slice of a texture with borders, sliced, tiled
// or filled. A RawImage draws the texture itself and lets `uv_rect` say which
// part: a background that scrolls by moving the rect, or one that repeats by
// a rect larger than 1 on a texture whose wrap is Repeat.

import "moonhug:packages/engine"

@(component={menu="UI/RawImage", icon="PHOTO"})
@(typ_guid={guid = "3a9d5e70-c184-4b2f-8d06-e5f17a2c9b84"})
RawImage :: struct {
	using base:    engine.CompData `inspect:"-"`,
	using graphic: engine.Graphic `inline:""`,
	texture:       engine.PPtr `ext:"png,jpg,jpeg,bmp" decor:tooltip(desc="The texture to draw. None draws a solid colour.")`,
	uv_rect:       [4]f32 `decor:tooltip(desc="The part of the texture that shows: x, y, width and height, where 0, 0, 1, 1 is the whole of it and y runs up. A size over 1 repeats a texture whose wrap is Repeat.")`,
}

type_reset_RawImage :: proc(r: ^RawImage) {
	r.color = {1, 1, 1, 1}
	r.raycast_target = true
	r.uv_rect = {0, 0, 1, 1}
}

// The uvs of a uv rect (x, y, width, height, y up), bl br tr tl: v runs
// down in the texture, so the rect's bottom is the larger v.
raw_image_uvs :: proc(uv_rect: [4]f32) -> [4][2]f32 {
	u0, u1 := uv_rect.x, uv_rect.x + uv_rect.z
	v_bottom, v_top := 1 - uv_rect.y, 1 - (uv_rect.y + uv_rect.w)
	return {{u0, v_bottom}, {u1, v_bottom}, {u1, v_top}, {u0, v_top}}
}

@(canvas_graphic)
canvas_populate_RawImage :: proc(r: ^RawImage, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	tex := r.texture.guid
	if engine.asset_guid_is_empty(tex) {
		append(out, engine.Graphic_Quad{pos = rect.pos, size = rect.size, uvs = engine.QUAD_UVS_FULL, texture = white_texture_guid()})
		return
	}
	append(out, engine.Graphic_Quad{pos = rect.pos, size = rect.size, uvs = raw_image_uvs(r.uv_rect), texture = tex})
}

// A RawImage wants its texture's size.
@(canvas_measure)
canvas_measure_RawImage :: proc(r: ^RawImage, width: f32) -> [2]f32 {
	if engine.asset_guid_is_empty(r.texture.guid) do return {}
	t, ok := engine.texture_load(r.texture.guid)
	if !ok do return {}
	return {f32(t.width) * abs(r.uv_rect.z), f32(t.height) * abs(r.uv_rect.w)}
}
