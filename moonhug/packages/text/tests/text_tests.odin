package text_tests

// Layout through a fake monospace backend: every glyph 10 wide and 12 tall,
// advance 10, ascent 10, descent 2, no gap, no kerning. That is what makes
// line breaks and alignment checkable to the pixel, and it is also the proof
// that the backend seam holds: nothing here touches stb_truetype.

import "core:testing"
import "core:math/linalg"
import "core:strings"
import "moonhug:engine"
import text "moonhug:packages/text"
import common "moonhug:tests/common"

@(private = "file")
_fake_metrics :: proc(font: engine.Asset_GUID, size_px: f32) -> (text.Line_Metrics, bool) {
	return {ascent = 10, descent = 2, line_gap = 0}, true
}

@(private = "file")
_fake_glyph :: proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (text.Glyph, bool) {
	g := text.Glyph{advance = 10, texture = font}
	if r != ' ' {
		g.size = {10, 12}
		g.offset = {0, -2}
		g.uvs = engine.QUAD_UVS_FULL
	}
	return g, true
}

@(private = "file")
_fake_backend :: proc() -> text.Backend {
	return text.Backend{name = "fake", metrics = _fake_metrics, glyph = _fake_glyph}
}

@(private = "file")
_font :: proc() -> engine.Asset_GUID {
	g: engine.Asset_GUID
	g[0] = 1
	return g
}

@(test)
test_layout_wraps_at_spaces_and_breaks_on_newline :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	// 55 wide: "hello" (50) fits, "hello world" (110) does not -> two lines.
	// Then a hard break.
	rect := engine.Rect{{0, 0}, {55, 100}}
	ok := text.layout_text(&b, _font(), 12, "hello world\nx", rect, .Upper_Left, true, 1, &out)
	testing.expect(t, ok, "layout runs")
	testing.expect_value(t, len(out), 11) // hello(5) world(5) x(1); spaces draw nothing
	// First line baseline: top - ascent = 100 - 10 = 90; glyph bottom = 88.
	testing.expect_value(t, out[0].pos, [2]f32{0, 88})
	testing.expect_value(t, out[4].pos, [2]f32{40, 88})
	// "world" on line 2, 12 lower.
	testing.expect_value(t, out[5].pos, [2]f32{0, 76})
	// "x" on line 3.
	testing.expect_value(t, out[10].pos, [2]f32{0, 64})
}

@(test)
test_layout_alignment :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{100, 100}, {200, 60}}
	// "ab" is 20 wide, one line 12 tall.
	text.layout_text(&b, _font(), 12, "ab", rect, .Middle_Center, false, 1, &out)
	testing.expect_value(t, len(out), 2)
	// Centered: x = 100 + (200-20)/2 = 190; block 12 tall centered in 60:
	// top = 160 - 24 = 136, baseline 126, glyph bottom 124.
	testing.expect_value(t, out[0].pos, [2]f32{190, 124})
	clear(&out)
	text.layout_text(&b, _font(), 12, "ab", rect, .Lower_Right, false, 1, &out)
	// Right: x = 100 + 200 - 20 = 280; bottom: top = 100 + 12 = 112, baseline 102, bottom 100.
	testing.expect_value(t, out[0].pos, [2]f32{280, 100})
	// No wrap: a long word runs past the rect instead of breaking.
	clear(&out)
	text.layout_text(&b, _font(), 12, "abcdefghijklmnopqrstuvwxyz", engine.Rect{{0, 0}, {50, 20}}, .Upper_Left, false, 1, &out)
	testing.expect_value(t, len(out), 26)
	testing.expect_value(t, out[25].pos.x, 250)
}

@(test)
test_collector_emits_glyph_quads_through_any_backend :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// The fake backend stands in for stb: the plugin's own seam, exercised.
	defer text.backend_set(text.stb_backend())

	canvas := engine.transform_new("Canvas")
	_, cv := engine.transform_add_comp(canvas, .Canvas)
	(cast(^engine.CompData)cv).enabled = true
	node := engine.transform_new("Text", canvas)
	_, rtp := engine.transform_add_comp(node, .RectTransform)
	rt := cast(^engine.RectTransform)rtp
	rt.enabled = true
	_, crp := engine.transform_add_comp(node, .CanvasRenderer)
	(cast(^engine.CompData)crp).enabled = true
	_, txp := engine.transform_add_comp(node, .Text)
	tx := cast(^text.Text)txp
	tx.enabled = true
	tx.text = strings.clone("hi") // owned: cleanup_Text frees it with the world
	tx.font = _font()
	tx.font_size = 12
	tx.color = {0, 1, 0, 1}

	text.text_package_init() // registers Text as a graphic (and the stb backend, replaced above)
	text.backend_set(_fake_backend())
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF)
	out := make([dynamic]engine.Render_Command)
	defer delete(out)
	engine.canvas_collect_graphics(view, &out)
	testing.expect_value(t, len(out), 2) // one quad per glyph
	if len(out) != 2 do return
	q := out[0].variant.(engine.Draw_Quad)
	testing.expect_value(t, q.color, [4]f32{0, 1, 0, 1})
	testing.expect_value(t, q.texture, _font())
	testing.expect_value(t, out[0].key[0] >> 56, u64(255))
}
