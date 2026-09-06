package text

// Text for the canvas tree (docs/Text.md). A plugin: the engine's canvas
// tree and packages/mhgui know nothing about it. A node with a
// CanvasRenderer and a Text draws its string inside its rect. Layout (lines,
// wrapping, alignment) lives here; glyph rasterization is a Backend
// (backend.odin), stb_truetype by default, swappable by another package.

import "moonhug:engine"

// Where the text block sits inside the rect, and how lines align.
Text_Anchor :: enum u8 {
	Upper_Left, Upper_Center, Upper_Right,
	Middle_Left, Middle_Center, Middle_Right,
	Lower_Left, Lower_Center, Lower_Right,
}

@(component={menu="UI/Text"})
@(typ_guid={guid = "2b6db0df-7473-4c2a-864d-8b0820b6b1a6"})
Text :: struct {
	using base:    engine.CompData `inspect:"-"`,
	// The fields every graphic shares (color, material, raycast target).
	using graphic: engine.Graphic `inline:""`,
	text:          string,
	font:          engine.Asset_GUID `ext:"ttf,otf"`, // a font file in assets; empty draws nothing
	font_size:     f32, // canvas units
	alignment:     Text_Anchor,
	wrap:         bool, // break lines at the rect's width
	line_spacing: f32,  // multiplier on the font's line height
}

reset_Text :: proc(t: ^Text) {
	t.font_size = 24
	t.color = {1, 1, 1, 1}
	t.wrap = true
	t.line_spacing = 1
}

// The Text's geometry: one quad per glyph from layout_text through the
// current backend (engine.Graphic_Desc.populate).
populate_text :: proc(comp: rawptr, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	tx := cast(^Text)comp
	if engine.asset_guid_is_empty(tx.font) do return
	quads := make([dynamic]Glyph_Quad, context.temp_allocator)
	if !layout_text(backend(), tx.font, tx.font_size, tx.text, rect, tx.alignment, tx.wrap, tx.line_spacing, &quads) do return
	for q in quads {
		append(out, engine.Graphic_Quad{pos = q.pos, size = q.size, uvs = q.uvs, texture = q.texture})
	}
}

cleanup_Text :: proc(t: ^Text) {
	if t.text != "" do delete(t.text)
	t.text = ""
}
