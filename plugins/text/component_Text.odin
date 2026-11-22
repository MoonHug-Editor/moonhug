package text

// Text for the canvas tree (plugins/text/docs/components/Text.md): a graphic
// whose font is an SDF artifact baked at import and whose glyphs go through
// an SDF material (assets/materials/TextSDF.mat), so it stays sharp at any
// size and gets outline, underlay shadow, dilation and softness from the
// shader. Layout (layout.odin) is backend-neutral; the SDF font is the glyph
// source behind the Backend seam (backend.odin), swappable by another package.

import "base:runtime"
import "core:hash"
import "core:strings"
import "moonhug:packages/engine"

@(component={menu="UI/Text"})
@(typ_guid={guid = "32d4e528-8898-4fd3-9fc4-2ac0cc34609e"})
Text :: struct {
	using base:    engine.CompData `inspect:"-"`,
	// The fields every graphic shares. `material` must be an SDF material
	// (TextSDF.mat ships with the package); the plain unlit shader would draw
	// the raw distance field.
	using graphic: engine.Graphic `inline:""`,
	text:          string `inspect:"-"`, // a text area in the editor (editor/text_editor.odin)
	font:          engine.PPtr `ext:"ttf,otf"`, // a font file in assets; empty draws nothing
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

type_reset_Text :: proc(t: ^Text) {
	type_cleanup_Text(t)
	t.font_size = 36
	t.auto_size_min = 18
	t.auto_size_max = 72
	t.color = {1, 1, 1, 1}
	t.raycast_target = true
	t.wrap = true
	t.kerning = true
}

type_cleanup_Text :: proc(t: ^Text) {
	if t.text != "" do delete(t.text)
	t.text = ""
	_layout_drop(t)
}

text_layout_params :: proc(t: ^Text) -> Layout_Params {
	return Layout_Params{
		font              = engine.asset_key(t.font),
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
// backend.
//
// The canvas is collected several times a frame (each view, picking, the
// shadow pass), and a layout costs far more than a copy, so a Text keeps its
// quads until something they depend on changes: its string, its settings,
// its rect, the font or the backend (_layout_key).
@(canvas_graphic)
canvas_populate_Text :: proc(tx: ^Text, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	if tx.font == {} do return
	content := text_content_rect(tx, rect)
	str := text_display_string(tx)
	p := text_layout_params(tx)
	key := _layout_key(tx, p, str, content)
	if kept, has := &_layouts[tx]; has && kept.key == key {
		append(out, ..kept.quads[:])
		return
	}
	text_layouts_made += 1
	p.size = text_fitted_size(tx, backend(), str, content)
	quads := make([dynamic]Glyph_Quad, context.temp_allocator)
	// A font that is not there yet is asked for again the next time.
	if !layout_text(backend(), p, str, content, &quads).ok do return
	context.allocator = runtime.default_allocator()
	kept := _layouts[tx]
	kept.key = key
	if kept.quads == nil do kept.quads = make([dynamic]engine.Graphic_Quad)
	clear(&kept.quads)
	for q in quads {
		append(&kept.quads, engine.Graphic_Quad{pos = q.pos, size = q.size, skew = q.skew, uvs = q.uvs, texture = q.texture})
	}
	_layouts[tx] = kept
	append(out, ..kept.quads[:])
}

// How large the Text wants its node: its string laid out at its font size,
// wrapped at `width` when the Text wraps (no limit at 0 or less), with the
// margins added. What a ContentSizeFitter and a LayoutGroup size it by.
@(canvas_measure)
canvas_measure_Text :: proc(tx: ^Text, width: f32) -> [2]f32 {
	if tx.font == {} do return {}
	p := text_layout_params(tx)
	margins := [2]f32{tx.margins[0] + tx.margins[2], tx.margins[1] + tx.margins[3]}
	// Laid out in a rect as wide as it may be and as tall as anything.
	HUGE :: f32(1e6)
	limit := width - margins.x if width > 0 && tx.wrap else HUGE
	str := text_display_string(tx)
	area := engine.Rect{pos = {0, 0}, size = {max(limit, 1), HUGE}}
	// Kept like the layout: asked on every resolve of the canvas.
	key := _layout_key(tx, p, str, area)
	if kept, has := _measures[tx]; has && kept.key == key do return kept.size
	quads := make([dynamic]Glyph_Quad, context.temp_allocator)
	res := layout_text(backend(), p, str, area, &quads)
	if !res.ok do return {}
	size := [2]f32{res.size.x + margins.x, res.size.y + margins.y}
	context.allocator = runtime.default_allocator()
	_measures[tx] = {key, size}
	return size
}

@(private = "file")
_measures: map[^Text]struct {
	key:  u64,
	size: [2]f32,
}

// A Text's quads and what they were made from. The map and the quads live
// for the process, so they are the default allocator's.
@(private = "file")
_Kept_Layout :: struct {
	key:   u64,
	quads: [dynamic]engine.Graphic_Quad,
}

@(private = "file")
_layouts: map[^Text]_Kept_Layout

// How many times a Text was laid out, a kept layout not counted: for tests
// and for a look at what a frame costs.
text_layouts_made: int

// A hash of everything a Text's quads depend on.
@(private = "file")
_layout_key :: proc(tx: ^Text, p: Layout_Params, str: string, content: engine.Rect) -> u64 {
	Inputs :: struct {
		params:    Layout_Params,
		content:   engine.Rect,
		auto_size: bool,
		auto_min:  f32,
		auto_max:  f32,
		epoch:     u64,
	}
	// Zeroed first: the padding between fields is part of the bytes hashed.
	inputs: Inputs
	inputs.params = p
	inputs.content = content
	inputs.auto_size, inputs.auto_min, inputs.auto_max = tx.auto_size, tx.auto_size_min, tx.auto_size_max
	inputs.epoch = _layout_epoch
	h := hash.fnv64a(transmute([]u8)str)
	return hash.fnv64a((cast([^]u8)&inputs)[:size_of(Inputs)], h)
}

// Forgets a Text's kept layout: the component is going away.
@(private = "file")
_layout_drop :: proc(tx: ^Text) {
	delete_key(&_measures, tx)
	kept, has := _layouts[tx]
	if !has do return
	delete(kept.quads)
	delete_key(&_layouts, tx)
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
}
