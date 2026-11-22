package mhgui

// Effects: components that change the quads of the graphic on their node
// after the graphic made them (engine @(canvas_effect)). They work on any
// graphic: an Image, a Text, a UiPolygon.
//
// - UiGradient colours the quads' corners, so the graphic's colour runs from
//   one colour to another across it.
// - UiShadow adds a copy of the quads behind them, moved and in its own colour.
// - UiOutline adds eight copies round them.
//
// Effects on one node run in the order of its components: a UiShadow after a
// UiOutline shadows the outline too.

import "core:math/linalg"
import "moonhug:packages/engine"

Gradient_Direction :: enum u8 {
	Vertical,   // `from` at the top, `to` at the bottom
	Horizontal, // `from` at the left, `to` at the right
}

Gradient_Span :: enum u8 {
	Content, // across what the graphic draws: the whole block of a Text
	Rect,    // across the node's rect
	Each,    // across each quad: every glyph of a Text
}

@(component={menu="UI/Effects/UiGradient"})
@(typ_guid={guid = "4b1f0c7a-2d63-4e8b-9a15-c3e7d8f2a640"})
UiGradient :: struct {
	using base: engine.CompData `inspect:"-"`,
	direction:  Gradient_Direction,
	span:       Gradient_Span `decor:tooltip(desc="What the gradient runs across: everything the graphic draws, the node's rect, or each quad by itself (every glyph of a Text).")`,
	from:       [4]f32 `decor:color() decor:tooltip(desc="The colour at the top or the left. It multiplies the graphic's own colour.")`,
	to:         [4]f32 `decor:color() decor:tooltip(desc="The colour at the bottom or the right. It multiplies the graphic's own colour.")`,
}

@(component={menu="UI/Effects/UiShadow"})
@(typ_guid={guid = "9e2a5d18-7c40-4f36-b1d9-0a6c4e8f3b27"})
UiShadow :: struct {
	using base: engine.CompData `inspect:"-"`,
	color:      [4]f32 `decor:color() decor:tooltip(desc="The shadow's colour. Its alpha is multiplied by the graphic's.")`,
	offset:     [2]f32 `decor:tooltip(desc="How far the shadow is moved, in canvas units, y up.")`,
}

@(component={menu="UI/Effects/UiOutline"})
@(typ_guid={guid = "c5d81e3f-6a02-49b7-8e4c-1f7b9a0d2e53"})
UiOutline :: struct {
	using base: engine.CompData `inspect:"-"`,
	color:      [4]f32 `decor:color() decor:tooltip(desc="The outline's colour. Its alpha is multiplied by the graphic's.")`,
	width:      f32 `decor:min(0) decor:tooltip(desc="How far the outline reaches, in canvas units.")`,
}

type_reset_UiGradient :: proc(g: ^UiGradient) {
	g.from = {1, 1, 1, 1}
	g.to = {0.6, 0.6, 0.6, 1}
}

type_reset_UiShadow :: proc(s: ^UiShadow) {
	s.color = {0, 0, 0, 0.5}
	s.offset = {1, -1}
}

type_reset_UiOutline :: proc(o: ^UiOutline) {
	o.color = {0, 0, 0, 1}
	o.width = 1
}

@(canvas_effect)
canvas_effect_UiGradient :: proc(g: ^UiGradient, rect: engine.Rect, quads: ^[dynamic]engine.Graphic_Quad) {
	if len(quads) == 0 do return
	lo, hi := rect.pos, rect.pos + rect.size
	if g.span == .Content {
		lo, hi = {max(f32), max(f32)}, {min(f32), min(f32)}
		for q in quads {
			for p in engine.graphic_quad_points(q) {
				lo = linalg.min(lo, p)
				hi = linalg.max(hi, p)
			}
		}
	}
	for &q in quads {
		points := engine.graphic_quad_points(q)
		if g.span == .Each {
			lo, hi = points[0], points[0]
			for p in points[1:] {
				lo = linalg.min(lo, p)
				hi = linalg.max(hi, p)
			}
		}
		for p, k in points {
			// 0 at `from`: the top, or the left.
			t: f32
			if g.direction == .Vertical {
				t = (hi.y - p.y) / (hi.y - lo.y) if hi.y > lo.y else 0
			} else {
				t = (p.x - lo.x) / (hi.x - lo.x) if hi.x > lo.x else 0
			}
			c := g.from + (g.to - g.from) * clamp(t, 0, 1)
			q.colors[k] = q.colors[k] * c if q.colored else c
		}
		q.colored = true
	}
}

// Puts a copy of the first `count` quads, moved by `offset` and in `color`,
// before the quads: behind them. The copy keeps its own colour, with the
// graphic's alpha and each corner's.
@(private = "file")
_copies_behind :: proc(quads: ^[dynamic]engine.Graphic_Quad, offsets: [][2]f32, color: [4]f32) {
	count := len(quads)
	if count == 0 || len(offsets) == 0 do return
	added := count * len(offsets)
	resize(quads, count + added)
	// The originals move to the end, last first.
	for i := count - 1; i >= 0; i -= 1 do quads[i + added] = quads[i]
	for offset, o in offsets {
		for i in 0 ..< count {
			src := quads[added + i]
			q := src
			points := engine.graphic_quad_points(src)
			for &p in points do p += offset
			q.free = true
			q.corners = points
			q.absolute = true
			for k in 0 ..< 4 {
				alpha := src.colors[k].a if src.colored else 1
				q.colors[k] = {color.r, color.g, color.b, color.a * alpha}
			}
			q.colored = true
			quads[o * count + i] = q
		}
	}
}

@(canvas_effect)
canvas_effect_UiShadow :: proc(s: ^UiShadow, rect: engine.Rect, quads: ^[dynamic]engine.Graphic_Quad) {
	if s.color.a <= 0 do return
	_copies_behind(quads, {s.offset}, s.color)
}

@(canvas_effect)
canvas_effect_UiOutline :: proc(o: ^UiOutline, rect: engine.Rect, quads: ^[dynamic]engine.Graphic_Quad) {
	if o.color.a <= 0 || o.width <= 0 do return
	w := o.width
	d := w * 0.7071
	_copies_behind(quads, {{w, 0}, {-w, 0}, {0, w}, {0, -w}, {d, d}, {-d, d}, {d, -d}, {-d, -d}}, o.color)
}
