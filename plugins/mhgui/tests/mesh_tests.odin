package mhgui_tests

// Mesh output of UI graphics: the Filled image's bars and sectors, the
// UiPolygon's triangles, and the effects that colour and copy quads.

import "core:testing"
import "moonhug:packages/engine"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

// The area the quads cover, by their corners: a triangle is a quad with two
// corners at one point.
@(private = "file")
_area :: proc(quads: []engine.Graphic_Quad) -> f32 {
	sum := f32(0)
	for q in quads {
		p := engine.graphic_quad_points(q)
		a := f32(0)
		for k in 0 ..< 4 {
			n := (k + 1) % 4
			a += p[k].x * p[n].y - p[n].x * p[k].y
		}
		sum += abs(a) * 0.5
	}
	return sum
}

@(private = "file")
_tex :: proc() -> engine.Asset_GUID {
	g: engine.Asset_GUID
	g[0] = 7
	return g
}

@(private = "file")
_close :: proc(t: ^testing.T, got, want: f32, what: string, loc := #caller_location) {
	testing.expectf(t, abs(got - want) < 0.05, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(test)
test_image_filled_bars_and_sectors :: proc(t: ^testing.T) {
	out := make([dynamic]engine.Graphic_Quad)
	defer delete(out)
	rect := engine.Rect{pos = {10, 20}, size = {100, 50}}
	whole := rect.size.x * rect.size.y
	fill :: proc(out: ^[dynamic]engine.Graphic_Quad, rect: engine.Rect, method: mhgui.Fill_Method, origin: mhgui.Fill_Origin, amount: f32, clockwise := true) {
		clear(out)
		mhgui.image_filled(out, _tex(), engine.QUAD_UVS_FULL, rect, method, origin, amount, clockwise)
	}

	// A bar from the left: a quarter of the width, and a quarter of the uvs.
	fill(&out, rect, .Horizontal, .Left, 0.25)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].pos, [2]f32{10, 20})
	testing.expect_value(t, out[0].size, [2]f32{25, 50})
	_close(t, out[0].uvs[1].x, 0.25, "the bar's right edge in the texture")
	// From the right it keeps the texture's right end.
	fill(&out, rect, .Horizontal, .Right, 0.25)
	testing.expect_value(t, out[0].pos, [2]f32{85, 20})
	_close(t, out[0].uvs[0].x, 0.75, "the bar's left edge in the texture")
	fill(&out, rect, .Vertical, .Top, 0.5)
	testing.expect_value(t, out[0].pos, [2]f32{10, 45})
	// uv v runs down: the top half is v 0 to 0.5.
	_close(t, out[0].uvs[0].y, 0.5, "the bar's bottom edge in the texture")

	fill(&out, rect, .Horizontal, .Left, 0)
	testing.expect_value(t, len(out), 0)

	// Sectors cover their share of the rect whatever its shape, since a
	// sector of a rect is cut by angle: check the ones whose share is plain.
	fill(&out, rect, .Radial_360, .Top, 0.5)
	_close(t, _area(out[:]) / whole, 0.5, "half a turn is half the rect")
	// Clockwise from the top: the right half.
	for q in out do for p in engine.graphic_quad_points(q) do testing.expectf(t, p.x >= 59.99, "the right half only: %v", p)
	fill(&out, rect, .Radial_360, .Top, 0.5, clockwise = false)
	for q in out do for p in engine.graphic_quad_points(q) do testing.expectf(t, p.x <= 60.01, "the left half only: %v", p)
	fill(&out, rect, .Radial_360, .Bottom, 1)
	testing.expect_value(t, len(out), 1)
	_close(t, _area(out[:]) / whole, 1, "a whole turn is the rect")
	fill(&out, rect, .Radial_360, .Left, 0.999)
	_close(t, _area(out[:]) / whole, 1, "almost a whole turn is almost the rect")
	fill(&out, rect, .Radial_180, .Bottom, 1)
	_close(t, _area(out[:]) / whole, 1, "a whole half turn is the rect")
	fill(&out, rect, .Radial_180, .Left, 0.5)
	_close(t, _area(out[:]) / whole, 0.5, "half of a half turn is half the rect")
	for origin in mhgui.Fill_Origin {
		fill(&out, rect, .Radial_90, origin, 1)
		_close(t, _area(out[:]) / whole, 1, "a whole quarter turn is the rect")
	}
	// A sector's uvs follow its points.
	fill(&out, rect, .Radial_360, .Right, 0.25)
	for q in out {
		for p, k in engine.graphic_quad_points(q) {
			_close(t, q.uvs[k].x, (p.x - 10) / 100, "u follows x")
			_close(t, q.uvs[k].y, 1 - (p.y - 20) / 50, "v follows y, downward")
		}
	}
}

@(test)
test_polygon_triangulates_a_concave_outline :: proc(t: ^testing.T) {
	// An L, counter-clockwise, area 3.
	l := [][2]f32{{0, 0}, {2, 0}, {2, 1}, {1, 1}, {1, 2}, {0, 2}}
	tris := mhgui.polygon_triangulate(l)
	testing.expect_value(t, len(tris), (len(l) - 2) * 3)
	area := f32(0)
	for i := 0; i + 2 < len(tris); i += 3 {
		a, b, c := l[tris[i]], l[tris[i + 1]], l[tris[i + 2]]
		area += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5
	}
	_close(t, area, 3, "the triangles cover the L and nothing else")
	// The other winding gives the same cover.
	rev := [][2]f32{{0, 2}, {1, 2}, {1, 1}, {2, 1}, {2, 0}, {0, 0}}
	tris = mhgui.polygon_triangulate(rev)
	area = 0
	for i := 0; i + 2 < len(tris); i += 3 {
		a, b, c := rev[tris[i]], rev[tris[i + 1]], rev[tris[i + 2]]
		area += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5
	}
	_close(t, area, 3, "clockwise too")

	// A square's outline moved out by 1 is a square 2 larger, corners sharp.
	square := [][2]f32{{0, 0}, {4, 0}, {4, 4}, {0, 4}} // counter-clockwise: right is outward
	grown := mhgui.polygon_offset(square, true, 1)
	_close(t, grown[0].x, -1, "the first corner's x")
	_close(t, grown[0].y, -1, "the first corner's y")
	_close(t, grown[2].x, 5, "the far corner's x")
	_close(t, grown[2].y, 5, "the far corner's y")
}

@(test)
test_polygon_graphic_fills_and_strokes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	out := make([dynamic]engine.Graphic_Quad)
	defer delete(out)
	p: mhgui.UiPolygon
	mhgui.type_reset_UiPolygon(&p)
	defer mhgui.type_cleanup_UiPolygon(&p)
	append(&p.points, [2]f32{0, 0}, [2]f32{1, 0}, [2]f32{0.5, 1})
	rect := engine.Rect{pos = {0, 0}, size = {100, 100}}

	// No fade: one triangle, half the rect.
	p.antialias = false
	mhgui.canvas_populate_UiPolygon(&p, rect, &out)
	testing.expect_value(t, len(out), 1)
	_close(t, _area(out[:]), 5000, "the triangle's area")
	testing.expect(t, !out[0].colored, "a plain fill has no colour per corner")

	// With the fade: the triangle and a band of three quads whose outer
	// corners have no alpha.
	clear(&out)
	p.antialias = true
	mhgui.canvas_populate_UiPolygon(&p, rect, &out)
	testing.expect_value(t, len(out), 4)
	testing.expect(t, out[1].colored && out[1].colors[0].a == 1 && out[1].colors[2].a == 0, "the band fades outward")
	// The faded edge is outside the solid one: the whole is larger than the plain triangle.
	testing.expect(t, _area(out[:]) > 5000, "the fade lies round the outline")

	// A line and no fill: a band a segment, closed, in the line's colour.
	clear(&out)
	p.antialias = false
	p.fill = false
	p.line_width = 4
	p.line_color = {1, 0, 0, 1}
	mhgui.canvas_populate_UiPolygon(&p, rect, &out)
	testing.expect_value(t, len(out), 3)
	testing.expect(t, out[0].absolute && out[0].colors[0] == [4]f32{1, 0, 0, 1}, "the line keeps its own colour")
	p.closed = false
	clear(&out)
	mhgui.canvas_populate_UiPolygon(&p, rect, &out)
	testing.expect_value(t, len(out), 2)
}

@(test)
test_effects_colour_and_copy_quads :: proc(t: ^testing.T) {
	quads := make([dynamic]engine.Graphic_Quad)
	defer delete(quads)
	rect := engine.Rect{pos = {0, 0}, size = {100, 100}}
	reset :: proc(quads: ^[dynamic]engine.Graphic_Quad) {
		clear(quads)
		// Two glyph-like quads side by side, in the lower half of the rect.
		append(quads, engine.Graphic_Quad{pos = {0, 0}, size = {10, 20}, texture = _tex()})
		append(quads, engine.Graphic_Quad{pos = {10, 0}, size = {10, 40}, texture = _tex()})
	}

	// A gradient across the content: the top of the taller quad is `from`,
	// the bottom of both is `to`, the top of the shorter one is half way.
	g: mhgui.UiGradient
	g.from, g.to = {1, 1, 1, 1}, {0, 0, 0, 1}
	reset(&quads)
	mhgui.canvas_effect_UiGradient(&g, rect, &quads)
	testing.expect(t, quads[0].colored && quads[1].colored, "the quads are coloured")
	_close(t, quads[1].colors[2].r, 1, "the top of the content")
	_close(t, quads[1].colors[0].r, 0, "the bottom of the content")
	_close(t, quads[0].colors[2].r, 0.5, "half way up the content")
	// Across each quad: every top is `from`.
	g.span = .Each
	reset(&quads)
	mhgui.canvas_effect_UiGradient(&g, rect, &quads)
	_close(t, quads[0].colors[2].r, 1, "each quad's own top")
	// Across the rect: the content's top at 40 of 100 is 0.4.
	g.span = .Rect
	reset(&quads)
	mhgui.canvas_effect_UiGradient(&g, rect, &quads)
	_close(t, quads[1].colors[2].r, 0.4, "the content's top in the rect")
	g.direction = .Horizontal
	reset(&quads)
	mhgui.canvas_effect_UiGradient(&g, rect, &quads)
	_close(t, quads[1].colors[1].r, 0.8, "the right edge at 20 of 100, from the left")

	// A shadow: a copy of each quad before them, moved, in its own colour.
	s: mhgui.UiShadow
	s.color, s.offset = {0, 0, 0, 0.5}, {2, -3}
	reset(&quads)
	mhgui.canvas_effect_UiShadow(&s, rect, &quads)
	testing.expect_value(t, len(quads), 4)
	testing.expect(t, quads[0].absolute && quads[0].free && quads[0].colors[0] == [4]f32{0, 0, 0, 0.5}, "the copy is the shadow's colour")
	testing.expect_value(t, quads[0].corners[0], [2]f32{2, -3})
	testing.expect(t, !quads[2].absolute && quads[2].pos == [2]f32{0, 0}, "the originals follow, as they were")

	// An outline: eight copies of each. A shadow after it shadows them all.
	o: mhgui.UiOutline
	o.color, o.width = {1, 0, 0, 1}, 1
	reset(&quads)
	mhgui.canvas_effect_UiOutline(&o, rect, &quads)
	testing.expect_value(t, len(quads), 18)
	mhgui.canvas_effect_UiShadow(&s, rect, &quads)
	testing.expect_value(t, len(quads), 36)
	// A coloured quad's own alpha carries into its copy.
	reset(&quads)
	quads[0].colored = true
	quads[0].colors = {{1, 1, 1, 0}, {1, 1, 1, 0}, {1, 1, 1, 1}, {1, 1, 1, 1}}
	mhgui.canvas_effect_UiShadow(&s, rect, &quads)
	_close(t, quads[0].colors[0].a, 0, "no alpha where the quad had none")
	_close(t, quads[0].colors[2].a, 0.5, "the shadow's where it was whole")
}
