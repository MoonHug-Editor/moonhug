package text

// Text for the canvas tree (docs/Text.md), TextMeshPro-shaped: a graphic
// whose font is an SDF artifact baked at import and whose glyphs go through
// an SDF material (assets/materials/TextSDF.mat), so it stays sharp at any
// size and gets outline, underlay shadow, dilation and softness from the
// shader. Layout (layout.odin) is backend-neutral; the SDF font is the glyph
// source behind the Backend seam (backend.odin), swappable by another package.

import "base:runtime"
import "core:strings"
import "moonhug:engine"

@(component={menu="UI/Text"})
@(typ_guid={guid = "32d4e528-8898-4fd3-9fc4-2ac0cc34609e"})
Text :: struct {
	using base:    engine.CompData `inspect:"-"`,
	// The fields every graphic shares. `material` must be an SDF material
	// (TextSDF.mat ships with the package); the plain unlit shader would draw
	// the raw distance field.
	using graphic: engine.Graphic `inline:""`,
	text:          string `inspect:"-"`, // a text area in the editor (editor/text_editor.odin)
	font:          engine.Asset_GUID `ext:"ttf,otf"`, // a font file in assets; empty draws nothing
	font_style:    Font_Style `inspect:"-"`, // toggle buttons in the editor
	font_size:     f32, // canvas units
	auto_size:     bool, // the largest size in [auto_size_min, auto_size_max] whose layout fits the rect
	auto_size_min: f32,
	auto_size_max: f32,
	horizontal_alignment: Horizontal_Alignment,
	vertical_alignment:   Vertical_Alignment,
	wrap:          bool, // break lines at the rect's width
	overflow:      Text_Overflow,
	// Hundredths of the font size, added to the font's own spacing.
	character_spacing: f32,
	word_spacing:      f32,
	line_spacing:      f32,
	paragraph_spacing: f32,
	margins:       [4]f32, // left, top, right, bottom: canvas units taken off the rect
	kerning:       bool, // the font's pair adjustments
	parse_escape_characters: bool, // "\n", "\t" and "\\" typed into the string become the characters
}

reset_Text :: proc(t: ^Text) {
	t.font_size = 36
	t.auto_size_min = 18
	t.auto_size_max = 72
	t.color = {1, 1, 1, 1}
	t.raycast_target = true
	t.wrap = true
	t.kerning = true
}

cleanup_Text :: proc(t: ^Text) {
	if t.text != "" do delete(t.text)
	t.text = ""
}

text_layout_params :: proc(t: ^Text) -> Layout_Params {
	return Layout_Params{
		font              = t.font,
		size              = t.font_size,
		style             = t.font_style,
		horizontal        = t.horizontal_alignment,
		vertical          = t.vertical_alignment,
		wrap              = t.wrap,
		overflow          = t.overflow,
		character_spacing = t.character_spacing,
		word_spacing      = t.word_spacing,
		line_spacing      = t.line_spacing,
		paragraph_spacing = t.paragraph_spacing,
		kerning           = t.kerning,
	}
}

// The rect the text lays out in: the node's rect minus the margins.
text_content_rect :: proc(t: ^Text, rect: engine.Rect) -> engine.Rect {
	return engine.Rect{
		pos  = {rect.pos.x + t.margins[0], rect.pos.y + t.margins[3]},
		size = {rect.size.x - t.margins[0] - t.margins[2], rect.size.y - t.margins[1] - t.margins[3]},
	}
}

// The string as laid out: escape sequences resolved when the component asks.
text_display_string :: proc(t: ^Text, allocator := context.temp_allocator) -> string {
	if !t.parse_escape_characters || !strings.contains_rune(t.text, '\\') do return t.text
	b := strings.builder_make(0, len(t.text), allocator)
	s := t.text
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':  strings.write_byte(&b, '\n'); i += 1; continue
			case 't':  strings.write_byte(&b, '\t'); i += 1; continue
			case '\\': strings.write_byte(&b, '\\'); i += 1; continue
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// The font size the text draws at: font_size, or under auto_size the largest
// size in [auto_size_min, auto_size_max] whose layout does not overflow the
// rect, found by bisection.
text_fitted_size :: proc(t: ^Text, b: ^Backend, str: string, rect: engine.Rect) -> f32 {
	if !t.auto_size do return t.font_size
	lo := max(t.auto_size_min, 1)
	hi := max(t.auto_size_max, lo)
	p := text_layout_params(t)
	scratch := make([dynamic]Glyph_Quad, context.temp_allocator)
	size := lo
	for _ in 0 ..< 12 {
		mid := (lo + hi) * 0.5
		p.size = mid
		clear(&scratch)
		r := layout_text(b, p, str, rect, &scratch)
		if r.ok && !r.overflow {
			size = mid
			lo = mid
		} else {
			hi = mid
		}
	}
	return size
}

// The Text's geometry: one quad per glyph from the layout over the current
// backend (engine.Graphic_Desc.populate).
populate_text :: proc(comp: rawptr, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	tx := cast(^Text)comp
	if engine.asset_guid_is_empty(tx.font) do return
	content := text_content_rect(tx, rect)
	str := text_display_string(tx)
	p := text_layout_params(tx)
	p.size = text_fitted_size(tx, backend(), str, content)
	quads := make([dynamic]Glyph_Quad, context.temp_allocator)
	if !layout_text(backend(), p, str, content, &quads).ok do return
	for q in quads {
		append(out, engine.Graphic_Quad{pos = q.pos, size = q.size, skew = q.skew, uvs = q.uvs, texture = q.texture})
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
