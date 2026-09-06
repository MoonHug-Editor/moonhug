package text

// Text for the canvas tree (docs/Text.md), TextMeshPro-shaped: a graphic
// whose font is an SDF artifact baked at import and whose glyphs go through
// an SDF material (assets/materials/TextSDF.mat), so it stays sharp at any
// size and gets outline, underlay shadow, dilation and softness from the
// shader. Layout (layout.odin) is backend-neutral; the SDF font is the glyph
// source behind the Backend seam (backend.odin), swappable by another package.

import "base:runtime"
import "moonhug:engine"

@(component={menu="UI/Text"})
@(typ_guid={guid = "32d4e528-8898-4fd3-9fc4-2ac0cc34609e"})
Text :: struct {
	using base:    engine.CompData `inspect:"-"`,
	// The fields every graphic shares. `material` must be an SDF material
	// (TextSDF.mat ships with the package); the plain unlit shader would draw
	// the raw distance field.
	using graphic: engine.Graphic `inline:""`,
	text:          string,
	font:          engine.Asset_GUID `ext:"ttf,otf"`, // a font file in assets; empty draws nothing
	font_size:     f32, // canvas units
	alignment:     Text_Anchor,
	wrap:          bool, // break lines at the rect's width
	line_spacing:  f32,  // multiplier on the font's line height
}

reset_Text :: proc(t: ^Text) {
	t.font_size = 36
	t.color = {1, 1, 1, 1}
	t.wrap = true
	t.line_spacing = 1
}

cleanup_Text :: proc(t: ^Text) {
	if t.text != "" do delete(t.text)
	t.text = ""
}

// The Text's geometry: one quad per glyph from the layout over the current
// backend (engine.Graphic_Desc.populate).
populate_text :: proc(comp: rawptr, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	tx := cast(^Text)comp
	if engine.asset_guid_is_empty(tx.font) do return
	quads := make([dynamic]Glyph_Quad, context.temp_allocator)
	if !layout_text(backend(), tx.font, tx.font_size, tx.text, rect, tx.alignment, tx.wrap, tx.line_spacing, &quads) do return
	for q in quads {
		append(out, engine.Graphic_Quad{pos = q.pos, size = q.size, uvs = q.uvs, texture = q.texture})
	}
}

// ImportersInit is the asset-layer init phase both binaries run.
@(phase={key=ImportersInit, order=2})
text_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	context.allocator = runtime.default_allocator()
	_fonts = make(map[engine.Asset_GUID]Font)
	backend_set(sdf_backend())
	engine.asset_pipeline_add_reimport_hook(font_reimported)
	engine.canvas_graphic_register(engine.Graphic_Desc{
		key            = .Text,
		graphic_offset = offset_of(Text, graphic),
		populate       = populate_text,
	})
}
