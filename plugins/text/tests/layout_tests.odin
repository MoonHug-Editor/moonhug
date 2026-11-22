package text_tests

// Layout through a fake monospace backend: at size 12 every glyph is 10
// wide and 12 tall, advance 10, ascent 10, descent 2, no gap, no kerning,
// and everything scales with the size. That is what makes line breaks,
// alignment, styles and overflow checkable to the pixel, and it is also the
// proof that the backend seam holds: nothing here touches the SDF font.

import "core:testing"
import "core:math/linalg"
import "core:strings"
import "moonhug:packages/engine"
import text "moonhug:packages/text"
import common "moonhug:tests/common"

@(private = "file")
_fake_metrics :: proc(font: engine.Asset_GUID, size_px: f32) -> (text.Line_Metrics, bool) {
	s := size_px / 12
	return {ascent = 10 * s, descent = 2 * s, line_gap = 0}, true
}

@(private = "file")
_fake_glyph :: proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (text.Glyph, bool) {
	s := size_px / 12
	g := text.Glyph{advance = 10 * s, texture = font}
	if r != ' ' {
		g.size = {10 * s, 12 * s}
		g.offset = {0, -2 * s}
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

@(private = "file")
_params :: proc(wrap := false) -> text.Layout_Params {
	return text.Layout_Params{font = _font(), size = 12, wrap = wrap, kerning = true}
}

@(private = "file")
_near :: proc(t: ^testing.T, got, want: f32, what: string, loc := #caller_location) {
	testing.expectf(t, abs(got - want) < 1e-3, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(test)
test_layout_wraps_at_spaces_and_breaks_on_newline :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	// 55 wide: "hello" (50) fits, "hello world" (110) does not -> two lines.
	// Then a hard break.
	rect := engine.Rect{{0, 0}, {55, 100}}
	res := text.layout_text(&b, _params(wrap = true), "hello world\nx", rect, &out)
	testing.expect(t, res.ok)
	testing.expect(t, !res.overflow, "three lines of 12 fit in 100")
	testing.expect_value(t, len(out), 11) // hello + world + x, spaces draw nothing
	// First line hangs from the top: baseline 90, glyph bottom 88.
	_near(t, out[0].pos.y, 88, "line 1 bottom")
	_near(t, out[0].pos.x, 0, "line 1 start")
	_near(t, out[4].pos.x, 40, "5th glyph")
	// Second line one line height (12) lower.
	_near(t, out[5].pos.y, 76, "line 2 bottom")
	_near(t, out[5].pos.x, 0, "line 2 start")
	_near(t, out[10].pos.y, 64, "line 3 bottom")
}

@(test)
test_layout_alignment :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{0, 0}, {100, 50}}
	p := _params()
	p.horizontal = .Center
	p.vertical = .Middle
	text.layout_text(&b, p, "ab", rect, &out)
	testing.expect_value(t, len(out), 2)
	_near(t, out[0].pos.x, 40, "centered: (100 - 20) / 2")
	_near(t, out[0].pos.y, 19, "middle: block 12 centered at 25, baseline 21, bottom 19")
	clear(&out)
	p.horizontal = .Right
	p.vertical = .Bottom
	text.layout_text(&b, p, "ab", rect, &out)
	_near(t, out[0].pos.x, 80, "right")
	_near(t, out[0].pos.y, 0, "bottom: baseline 2, bottom 0")
	clear(&out)
	p.horizontal = .Left
	p.vertical = .Baseline
	text.layout_text(&b, p, "a", rect, &out)
	_near(t, out[0].pos.y, 23, "baseline on the center (25)")
	clear(&out)
	p.vertical = .Midline
	text.layout_text(&b, p, "a", rect, &out)
	_near(t, out[0].pos.y, 25 - 6 + 2 - 2, "midline: top at center + 6, baseline 19, bottom 17")
	clear(&out)
	p.vertical = .Capline
	text.layout_text(&b, p, "a", rect, &out)
	_near(t, out[0].pos.y, 25 - 7 - 2, "capline: baseline at center - 7")
}

@(test)
test_layout_without_wrap_reports_overflow :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	res := text.layout_text(&b, _params(), "abcdefghijklmnopqrstuvwxyz", engine.Rect{{0, 0}, {50, 20}}, &out)
	testing.expect_value(t, len(out), 26)
	_near(t, out[25].pos.x, 250, "one line, past the rect")
	testing.expect(t, res.overflow, "wider than the rect")
}

@(test)
test_layout_justified_and_flush :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{0, 0}, {70, 100}}
	p := _params(wrap = true)
	p.horizontal = .Justified
	// One hard line: Justified leaves a paragraph's last line ragged.
	text.layout_text(&b, p, "aa bb", rect, &out)
	testing.expect_value(t, len(out), 4)
	_near(t, out[2].pos.x, 30, "justified last line stays left")
	clear(&out)
	// Two lines: the wrapped first line spreads its slack over the space.
	text.layout_text(&b, p, "aa bb cc", rect, &out)
	testing.expect_value(t, len(out), 6)
	_near(t, out[2].pos.x, 50, "wrapped line: 'bb' pushed to the right edge")
	_near(t, out[4].pos.x, 0, "last line left")
	clear(&out)
	p.horizontal = .Flush
	text.layout_text(&b, p, "aa bb", rect, &out)
	_near(t, out[2].pos.x, 50, "flush spreads the last line too")
}

@(test)
test_layout_spacing_units_are_hundredths_of_the_size :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{0, 0}, {200, 100}}
	p := _params()
	p.character_spacing = 50 // 6 units at size 12
	p.word_spacing = 100     // 12 units
	p.line_spacing = 100     // 12 units
	p.paragraph_spacing = 50 // 6 units
	text.layout_text(&b, p, "ab c\nd", rect, &out)
	testing.expect_value(t, len(out), 4)
	_near(t, out[1].pos.x, 16, "advance 10 + character spacing 6")
	_near(t, out[2].pos.x, 16 + 16 + 10 + 6 + 12, "after the space: its advance, character and word spacing")
	_near(t, out[3].pos.y, 88 - 24 - 6, "next paragraph: line height 12 + 12, paragraph gap 6")
}

@(test)
test_layout_styles :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{0, 0}, {200, 100}}
	p := _params()

	p.style = {.Bold}
	text.layout_text(&b, p, "a", rect, &out)
	testing.expect_value(t, len(out), 2)
	_near(t, out[1].pos.x, 12 * text.BOLD_OFFSET, "bold: second copy offset")
	clear(&out)

	p.style = {.Italic}
	text.layout_text(&b, p, "a", rect, &out)
	_near(t, out[0].skew[0], -2 * text.ITALIC_SHEAR, "italic: bottom edge below the baseline leans left")
	_near(t, out[0].skew[1], 10 * text.ITALIC_SHEAR, "italic: top edge leans right")
	clear(&out)

	p.style = {.Underline}
	text.layout_text(&b, p, "ab", rect, &out)
	testing.expect_value(t, len(out), 3)
	_near(t, out[2].pos.x, 0, "underline starts at the line")
	_near(t, out[2].size.x, 20, "underline spans the line")
	_near(t, out[2].pos.y, 88, "underline sits where '_' sits")
	_near(t, out[2].uvs[0].x, 0.5, "underline samples the slab's center column")
	clear(&out)

	p.style = {.Strikethrough}
	text.layout_text(&b, p, "ab", rect, &out)
	_near(t, out[2].pos.y, 90 + 3 - 6, "strikethrough centered at 0.3 of the ascent")
	clear(&out)

	p.style = {.Smallcaps}
	text.layout_text(&b, p, "aA", rect, &out)
	_near(t, out[0].size.y, 12 * text.SMALLCAPS_SCALE, "lowercase drawn as a smaller capital")
	_near(t, out[1].size.y, 12, "capitals keep the size")
	_near(t, out[1].pos.x, 10 * text.SMALLCAPS_SCALE, "the smaller glyph advances less")
}

@(test)
test_layout_overflow_modes :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{{0, 0}, {55, 20}}
	p := _params()

	p.overflow = .Truncate
	res := text.layout_text(&b, p, "abcdefghij", rect, &out)
	testing.expect(t, res.overflow, "overflow is reported even when cut")
	testing.expect_value(t, len(out), 5) // 50 of 55 fit
	clear(&out)

	p.overflow = .Ellipsis
	text.layout_text(&b, p, "abcdefghij", rect, &out)
	testing.expect_value(t, len(out), 5) // "ab" (20) + "..." (30) within 55
	_near(t, out[4].pos.x, 40, "last dot")
	clear(&out)

	// Too many lines: the second line is dropped and the first ends in dots.
	p.wrap = true
	text.layout_text(&b, p, "abcd efgh", rect, &out)
	testing.expect_value(t, len(out), 5) // "ab..." from the 55 wide line, 20 tall rect fits one line
	clear(&out)

	p.wrap = false
	p.overflow = .Masking
	text.layout_text(&b, p, "abcdefghij", engine.Rect{{0, 0}, {15, 20}}, &out)
	testing.expect_value(t, len(out), 2) // 'a' whole, 'b' half, the rest gone
	_near(t, out[1].size.x, 5, "clipped width")
	_near(t, out[1].uvs[1].x, 0.5, "clipped uv")
}

@(test)
test_text_component_helpers :: proc(t: ^testing.T) {
	b := _fake_backend()
	tx: text.Text
	text.type_reset_Text(&tx)
	tx.font = engine.PPtr{guid = _font()}
	tx.text = "a\\nb"
	tx.parse_escape_characters = true
	testing.expect_value(t, text.text_display_string(&tx), "a\nb")

	tx.margins = {5, 1, 3, 2}
	r := text.text_content_rect(&tx, engine.Rect{{0, 0}, {100, 50}})
	_near(t, r.pos.x, 5, "left margin")
	_near(t, r.pos.y, 2, "bottom margin")
	_near(t, r.size.x, 92, "width minus left and right")
	_near(t, r.size.y, 47, "height minus top and bottom")

	// Five glyphs in 25 units: 10 * size / 12 each, so size 6 fits exactly.
	tx.auto_size = true
	tx.auto_size_min = 4
	tx.auto_size_max = 48
	tx.wrap = false
	size := text.text_fitted_size(&tx, &b, "abcde", engine.Rect{{0, 0}, {25, 100}})
	testing.expectf(t, abs(size - 6) < 0.05, "auto size: got %v, want 6", size)
}

@(test)
test_collector_emits_glyph_quads_through_any_backend :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// The fake backend stands in for the SDF font: the plugin's own seam, exercised.
	defer text.backend_set(text.sdf_backend())

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
	tx.text = strings.clone("hi") // type_cleanup_Text frees it on destroy
	tx.font = engine.PPtr{guid = _font()}
	tx.font_size = 12
	tx.color = {0, 1, 0, 1}

	text.text_package_init() // registers Text as a graphic (and the SDF backend, replaced below)
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

// A Text keeps its quads between collects and lays out again only when
// something they depend on changed.
@(test)
test_text_keeps_its_layout_until_it_changes :: proc(t: ^testing.T) {
	prev := text.backend()^
	text.backend_set(_fake_backend())
	defer text.backend_set(prev)

	tx: text.Text
	text.type_reset_Text(&tx)
	defer text.type_cleanup_Text(&tx)
	tx.font = engine.PPtr{guid = _font()}
	tx.font_size = 12
	tx.text = strings.clone("hello world")
	rect := engine.Rect{pos = {0, 0}, size = {300, 100}}
	out := make([dynamic]engine.Graphic_Quad, context.temp_allocator)

	made := text.text_layouts_made
	text.canvas_populate_Text(&tx, rect, &out)
	testing.expect_value(t, text.text_layouts_made, made + 1)
	testing.expect_value(t, len(out), 10) // a space has no quad
	first := out[0]

	// The same again, as the next view's collect asks: no new layout, the same quads.
	for _ in 0 ..< 5 {
		clear(&out)
		text.canvas_populate_Text(&tx, rect, &out)
	}
	testing.expect_value(t, text.text_layouts_made, made + 1)
	testing.expect_value(t, len(out), 10)
	testing.expect(t, out[0].pos == first.pos && out[0].size == first.size && out[0].uvs == first.uvs, "the kept quads are the same quads")

	// Each of these changes what is drawn: one new layout each.
	delete(tx.text)
	tx.text = strings.clone("hello there")
	clear(&out)
	text.canvas_populate_Text(&tx, rect, &out)
	testing.expect_value(t, text.text_layouts_made, made + 2)

	tx.font_size = 24
	clear(&out)
	text.canvas_populate_Text(&tx, rect, &out)
	testing.expect_value(t, text.text_layouts_made, made + 3)
	testing.expect(t, out[0].size.x > first.size.x, "the larger size is drawn, not the kept quads")

	clear(&out)
	text.canvas_populate_Text(&tx, engine.Rect{pos = {0, 0}, size = {100, 100}}, &out)
	testing.expect_value(t, text.text_layouts_made, made + 4)

	tx.horizontal_alignment = .Right
	clear(&out)
	text.canvas_populate_Text(&tx, engine.Rect{pos = {0, 0}, size = {100, 100}}, &out)
	testing.expect_value(t, text.text_layouts_made, made + 5)

	// Another backend, as a font reload is: laid out again.
	text.backend_set(_fake_backend())
	clear(&out)
	text.canvas_populate_Text(&tx, engine.Rect{pos = {0, 0}, size = {100, 100}}, &out)
	testing.expect_value(t, text.text_layouts_made, made + 6)
}

// A caret per rune and one for the end: on the line of its rune, at the pen.
@(test)
test_layout_carets :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	carets := make([dynamic]text.Caret)
	defer delete(carets)
	rect := engine.Rect{pos = {0, 0}, size = {200, 100}}

	// Top left by default. "ab\ncd": six carets, the line break's at the end
	// of the first line, the last after "cd".
	res := text.layout_text(&b, _params(), "ab\ncd", rect, &out, &carets)
	testing.expect(t, res.ok)
	testing.expect_value(t, len(carets), 6)
	for want, i in ([]f32{0, 10, 20, 0, 10, 20}) do _near(t, carets[i].pos.x, want, "caret x")
	for want, i in ([]int{0, 0, 0, 1, 1, 1}) do testing.expect_value(t, carets[i].line, want)
	_near(t, carets[0].pos.y, 88, "first line's bottom")
	_near(t, carets[3].pos.y, 76, "second line's bottom")
	_near(t, carets[0].height, 12, "caret height")

	// An empty string has one caret, where its text would start.
	clear(&carets)
	res = text.layout_text(&b, _params(), "", rect, &out, &carets)
	testing.expect(t, res.ok)
	testing.expect_value(t, len(carets), 1)
	_near(t, carets[0].pos.x, 0, "empty caret x")
	_near(t, carets[0].pos.y, 88, "empty caret y")

	// A string that ends with a line break: the end is on the new line.
	clear(&carets)
	text.layout_text(&b, _params(), "ab\n", rect, &out, &carets)
	testing.expect_value(t, len(carets), 4)
	testing.expect_value(t, carets[3].line, 1)
	_near(t, carets[3].pos.x, 0, "caret after the break")

	// Wrapped: the space the line wrapped at stands at its line's end.
	clear(&carets)
	p := _params(true)
	text.layout_text(&b, p, "aaa bbb", engine.Rect{pos = {0, 0}, size = {40, 100}}, &out, &carets)
	testing.expect_value(t, len(carets), 8)
	testing.expect_value(t, carets[3].line, 0)
	_near(t, carets[3].pos.x, 30, "caret at the wrap")
	testing.expect_value(t, carets[4].line, 1)
	_near(t, carets[4].pos.x, 0, "caret after the wrap")
	_near(t, carets[7].pos.x, 30, "caret at the end")
}

// Rich text: tags leave the string and set what their span draws with.
@(test)
test_rich_parse_tags :: proc(t: ^testing.T) {
	runes := make([dynamic]rune)
	defer delete(runes)
	spans := make([dynamic]text.Rich_Span)
	defer delete(spans)
	text.rich_parse("a<b>b<i>c</b>d</i>e", {}, 12, &runes, &spans)
	testing.expect_value(t, len(runes), 5)
	testing.expect_value(t, spans[0].style, text.Font_Style{})
	testing.expect_value(t, spans[1].style, text.Font_Style{.Bold})
	testing.expect_value(t, spans[2].style, text.Font_Style{.Bold, .Italic})
	testing.expect_value(t, spans[3].style, text.Font_Style{.Italic})
	testing.expect_value(t, spans[4].style, text.Font_Style{})

	// Colours nest, and a closing tag gives back the one around it.
	clear(&runes); clear(&spans)
	text.rich_parse(`a<color=#f00>b<COLOR="blue">c</color>d</color>e`, {}, 12, &runes, &spans)
	testing.expect_value(t, len(runes), 5)
	testing.expect(t, !spans[0].colored && !spans[4].colored, "outside the tags the Text's own colour")
	testing.expect_value(t, spans[1].color, [4]f32{1, 0, 0, 1})
	testing.expect_value(t, spans[2].color, [4]f32{0.25, 0.5, 1, 1})
	testing.expect_value(t, spans[3].color, [4]f32{1, 0, 0, 1})

	// Sizes: units, a share of the Text's size, and steps from the size around.
	clear(&runes); clear(&spans)
	text.rich_parse("a<size=24>b<size=+6>c</size>d</size><size=50%>e", {}, 12, &runes, &spans)
	for want, i in ([]f32{12, 24, 30, 24, 6}) do _near(t, spans[i].size, want, "span size")

	// What is no tag stays, brackets and all: a comparison, an unknown tag,
	// a bad colour, a bracket that never closes.
	testing.expect_value(t, text.rich_plain("a < b > c"), "a < b > c")
	testing.expect_value(t, text.rich_plain("<blink>x</blink>"), "<blink>x</blink>")
	testing.expect_value(t, text.rich_plain("<color=nope>x"), "<color=nope>x")
	testing.expect_value(t, text.rich_plain("x<b"), "x<b")
	testing.expect_value(t, text.rich_plain("<b>bold</b> and <u>under</u>"), "bold and under")
	// A closing tag with nothing open is taken out and changes nothing.
	testing.expect_value(t, text.rich_plain("a</b>b"), "ab")

	c, ok := text.rich_color("#80ff0040")
	testing.expect(t, ok && abs(c.r - 128.0 / 255) < 1e-4 && c.g == 1 && c.b == 0 && abs(c.a - 64.0 / 255) < 1e-4, "eight hex digits carry the alpha")
	c, ok = text.rich_color("#0f8")
	testing.expect(t, ok && c == [4]f32{0, 1, 136.0 / 255, 1}, "three hex digits, each doubled")
	_, ok = text.rich_color("#12")
	testing.expect(t, !ok, "two digits are no colour")
}

@(test)
test_layout_rich_text :: proc(t: ^testing.T) {
	b := _fake_backend()
	out := make([dynamic]text.Glyph_Quad)
	defer delete(out)
	rect := engine.Rect{pos = {0, 0}, size = {400, 200}}
	p := _params()
	p.rich = true

	// The tags take no room: "ab" with a colour on the b is two glyphs, 10 apart.
	res := text.layout_text(&b, p, "a<color=#ff0000>b</color>", rect, &out)
	testing.expect(t, res.ok)
	testing.expect_value(t, len(out), 2)
	_near(t, out[1].pos.x - out[0].pos.x, 10, "the tag takes no room")
	testing.expect(t, !out[0].colored && out[1].colored && out[1].color == [4]f32{1, 0, 0, 1}, "the span has its colour, the rest has none")
	_near(t, res.size.x, 20, "the line is two glyphs wide")

	// Off, the same string is text: every character draws.
	clear(&out)
	p.rich = false
	text.layout_text(&b, p, "a<b>b", rect, &out)
	testing.expect_value(t, len(out), 5)
	p.rich = true

	// A bold span draws its glyphs twice. The rest draws once.
	clear(&out)
	text.layout_text(&b, p, "a<b>b</b>c", rect, &out)
	testing.expect_value(t, len(out), 4)

	// A larger span: its glyphs are larger, and its line is as tall as it
	// needs. At size 24 the fake line is 24 tall, so the second line's
	// glyph sits 24 under the top and not 12.
	clear(&out)
	res = text.layout_text(&b, p, "a<size=24>B</size>\nc", rect, &out)
	testing.expect_value(t, len(out), 3)
	_near(t, out[1].size.y, 24, "the large glyph's height")
	// A fake glyph hangs a sixth of its size under the baseline.
	_near(t, out[0].pos.y + 2, out[1].pos.y + 4, "both glyphs of the line stand on one baseline")
	_near(t, res.size.y, 36, "a line of 24 and a line of 12")
	_near(t, out[2].pos.y, 200 - 36, "the second line's glyph ends at the block's bottom")
	_near(t, res.size.x, 30, "10 for a and 20 for B")

	// An underlined span has its rule under the span only, in its colour.
	clear(&out)
	text.layout_text(&b, p, "ab<u><color=blue>cd</color></u>ef", rect, &out)
	testing.expect_value(t, len(out), 7) // six glyphs and one rule
	rule := out[6]
	_near(t, rule.pos.x, 20, "the rule starts under c")
	_near(t, rule.size.x, 20, "and ends after d")
	testing.expect(t, rule.colored && rule.color == [4]f32{0.25, 0.5, 1, 1}, "the rule has the span's colour")

	// Carets count the runes that show.
	carets := make([dynamic]text.Caret)
	defer delete(carets)
	clear(&out)
	text.layout_text(&b, p, "a<b>b</b>", rect, &out, &carets)
	testing.expect_value(t, len(carets), 3)
}
