package text_tests

// The SDF artifact round trip, headless: bake Roboto at a small sampling
// size, parse the bytes back, and lay text out through the SDF backend with
// packages/text's layout. No GPU: the atlas texture stays empty, the
// metrics and glyph placement do not.

import "core:os"
import "core:testing"
import "moonhug:engine"
import text "moonhug:packages/text"

@(private = "file")
_roboto :: proc(t: ^testing.T) -> []u8 {
	data, err := os.read_entire_file("moonhug/packages/text/assets/Roboto-Medium.ttf", context.temp_allocator)
	testing.expect(t, err == nil, "the text package's Roboto is readable")
	return data
}

@(test)
test_font_bake_and_parse :: proc(t: ^testing.T) {
	ttf := _roboto(t)
	if len(ttf) == 0 do return
	s := text.FontSettings{sampling_size = 32, padding = 4, atlas_size = 256, latin1 = true}
	artifact, ok := text.font_bake(ttf, s)
	defer delete(artifact)
	testing.expect(t, ok, "bake succeeds (the atlas grows until the glyphs fit)")
	if !ok do return

	f, pok := text.font_parse(artifact)
	defer {
		delete(f.glyphs)
		delete(f.kerns)
	}
	testing.expect(t, pok, "artifact parses")
	if !pok do return
	testing.expect_value(t, f.header.glyph_count, u32(95 + 96))
	testing.expect_value(t, f.header.sampling, 32)
	testing.expect(t, f.header.ascent > 20 && f.header.ascent < 40, "ascent is in the sampling size's range")
	testing.expect(t, f.header.descent > 0, "descent stored positive")
	a := f.glyphs['A']
	testing.expect(t, a.x1 > a.x0 && a.y1 > a.y0, "A has a bitmap")
	testing.expect(t, a.advance > 10, "A advances")
	sp := f.glyphs[' ']
	testing.expect(t, sp.advance > 0, "space advances")
	testing.expect(t, len(f.atlas) == int(f.header.atlas_w) * int(f.header.atlas_h), "atlas bytes follow the tables")
	// A distance field has a mid value (edge) somewhere inside A's bitmap.
	edge_seen := false
	for y in int(a.y0) ..< int(a.y1) {
		for x in int(a.x0) ..< int(a.x1) {
			v := f.atlas[y * int(f.header.atlas_w) + x]
			if v > 100 && v < 156 do edge_seen = true
		}
	}
	testing.expect(t, edge_seen, "the field crosses the edge inside a glyph")
}

@(test)
test_sdf_backend_scales_metrics_and_lays_out :: proc(t: ^testing.T) {
	ttf := _roboto(t)
	if len(ttf) == 0 do return
	artifact, ok := text.font_bake(ttf, text.FontSettings{sampling_size = 32, padding = 4, atlas_size = 256, latin1 = false})
	testing.expect(t, ok, "bake")
	if !ok do return
	f, pok := text.font_parse(artifact)
	testing.expect(t, pok, "parse")
	if !pok do return
	guid: engine.Asset_GUID
	guid[0] = 7
	text.font_cache_insert(guid, f) // owns f (and the artifact bytes)

	b := text.sdf_backend()
	m32, mok := b.metrics(guid, 32)
	testing.expect(t, mok, "metrics at the sampling size")
	m64, _ := b.metrics(guid, 64)
	testing.expect(t, abs(m64.ascent - 2 * m32.ascent) < 1e-3, "metrics scale with the requested size")

	g32, _ := b.glyph(guid, 32, 'H')
	g64, _ := b.glyph(guid, 64, 'H')
	testing.expect(t, abs(g64.advance - 2 * g32.advance) < 1e-3, "advances scale")
	testing.expect(t, abs(g64.size.x - 2 * g32.size.x) < 1e-3, "glyph quads scale")

	quads := make([dynamic]text.Glyph_Quad)
	defer delete(quads)
	rect := engine.Rect{{0, 0}, {400, 100}}
	lok := text.layout_text(&b, text.Layout_Params{font = guid, size = 48}, "Hi", rect, &quads).ok
	testing.expect(t, lok, "layout through the SDF backend")
	testing.expect_value(t, len(quads), 2)
	if len(quads) == 2 {
		testing.expect(t, quads[1].pos.x > quads[0].pos.x, "glyphs advance left to right")
		testing.expect(t, quads[0].pos.y < 100 && quads[0].pos.y + quads[0].size.y <= 100 + 1, "first line hangs from the rect's top")
	}
	text.font_reimported(guid) // frees the cached font
}

// A glyph outside the baked ranges comes from the font file at first use,
// on the dynamic page; a glyph the font does not have falls back to '?'.
@(test)
test_sdf_backend_adds_glyphs_outside_the_bake :: proc(t: ^testing.T) {
	ttf := _roboto(t)
	if len(ttf) == 0 do return
	s := text.FontSettings{sampling_size = 32, padding = 4, atlas_size = 256, latin1 = false} // ASCII only
	artifact, ok := text.font_bake(ttf, s)
	testing.expect(t, ok)
	if !ok do return
	f, pok := text.font_parse(artifact)
	testing.expect(t, pok)
	if !pok do return
	testing.expect(t, f.has_info, "the artifact carries the font file")
	guid := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	text.font_cache_insert(guid, f)
	defer text.font_reimported(guid)

	b := text.sdf_backend()
	e_acute, eok := b.glyph(guid, 32, 'é')
	testing.expect(t, eok)
	testing.expect(t, e_acute.size.x > 0 && e_acute.size.y > 0, "the dynamic glyph has a bitmap")
	testing.expect(t, e_acute.texture != {}, "the dynamic glyph lives on the dynamic page")
	plain_e, _ := b.glyph(guid, 32, 'e')
	testing.expect(t, e_acute.texture != plain_e.texture, "the dynamic page is a second texture")
	testing.expect(t, abs(e_acute.advance - plain_e.advance) < 2, "é advances about like e")
	again, _ := b.glyph(guid, 32, 'é')
	testing.expect_value(t, again.uvs, e_acute.uvs) // cached, not packed twice

	snowman, sok := b.glyph(guid, 32, '☃')
	question, _ := b.glyph(guid, 32, '?')
	testing.expect(t, sok)
	testing.expect_value(t, snowman.uvs, question.uvs) // not in Roboto: the fallback
}
