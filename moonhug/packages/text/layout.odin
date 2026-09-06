package text

// Line breaking, alignment, styles and overflow, backend-neutral: the backend
// supplies advances and metrics, this turns a string and a rect into glyph
// quads in canvas units. Pure, so the tests drive it with a fake backend.

import "core:unicode"
import "moonhug:engine"

Horizontal_Alignment :: enum u8 {
	Left,
	Center,
	Right,
	Justified, // a wrapped line's slack goes into its spaces; a paragraph's last line stays left
	Flush,     // Justified, the last line too
}

Vertical_Alignment :: enum u8 {
	Top,
	Middle,
	Bottom,
	Baseline, // the first line's baseline on the rect's vertical center
	Midline,  // the first line's midpoint between ascent and descent on the center
	Capline,  // the first line's cap height on the center
}

// What happens to text past the rect.
Text_Overflow :: enum u8 {
	Overflow, // drawn past the rect
	Ellipsis, // cut at the last line that fits, ending in "..."
	Truncate, // cut at the last line that fits
	Masking,  // every quad clipped to the rect
}

Font_Style_Flag :: enum u8 {
	Bold,          // each glyph drawn twice, BOLD_OFFSET apart, with BOLD_SPACING between glyphs
	Italic,        // quads sheared by ITALIC_SHEAR around the baseline
	Underline,     // the font's '_' glyph stretched under each line
	Strikethrough, // the same slab through the line at STRIKETHROUGH_HEIGHT
	Lowercase,
	Uppercase,
	Smallcaps,     // lowercase letters as capitals at SMALLCAPS_SCALE of the size
}
Font_Style :: bit_set[Font_Style_Flag; u8]

ITALIC_SHEAR         :: 0.35 // x shift per unit of height above the baseline
BOLD_OFFSET          :: 0.02 // em
BOLD_SPACING         :: 7    // hundredths of an em
SMALLCAPS_SCALE      :: 0.8
STRIKETHROUGH_HEIGHT :: 0.3  // of the ascent, above the baseline
CAP_HEIGHT           :: 0.7  // of the ascent; the backend has no cap-height metric
TAB_SPACES           :: 4

// One glyph placed in canvas units: `pos` is the quad's bottom-left. `skew`
// shifts the bottom and the top edge along x (italic).
Glyph_Quad :: struct {
	pos:     [2]f32,
	size:    [2]f32,
	skew:    [2]f32,
	uvs:     [4][2]f32,
	texture: engine.Asset_GUID,
}

// Everything layout_text needs besides the string and the rect. Spacings
// are in hundredths of the font size, added to the font's own values.
Layout_Params :: struct {
	font:              engine.Asset_GUID,
	size:              f32,
	style:             Font_Style,
	horizontal:        Horizontal_Alignment,
	vertical:          Vertical_Alignment,
	wrap:              bool,
	overflow:          Text_Overflow,
	character_spacing: f32,
	word_spacing:      f32,
	line_spacing:      f32,
	paragraph_spacing: f32,
	kerning:           bool,
}

Layout_Result :: struct {
	ok:       bool, // the backend serves the font
	overflow: bool, // a line is wider than the rect or the block is taller, before any cut
}

@(private = "file")
_Line :: struct {
	first, last: int, // rune indices, [first, last)
	width:       f32,
	spaces:      int,  // spaces inside the line, for justification
	hard:        bool, // ends a paragraph: a '\n' or the end of the text
	ellipsis:    bool, // draws "..." after its last glyph
}

// Lays `text` out inside `rect`, appending one Glyph_Quad per visible glyph
// (two under Bold, plus one slab per line for Underline and Strikethrough).
// Lines break at '\n', and when `p.wrap` is set also at spaces once a line
// would pass the rect's width (a single word wider than the rect stays on its
// own line). A '\t' advances TAB_SPACES spaces.
layout_text :: proc(b: ^Backend, p: Layout_Params, text: string, rect: engine.Rect, out: ^[dynamic]Glyph_Quad) -> Layout_Result {
	if b.metrics == nil || b.glyph == nil do return {}
	m, ok := b.metrics(p.font, p.size)
	if !ok do return {}
	res := Layout_Result{ok = true}
	if text == "" do return res
	base := len(out)
	em := p.size * 0.01
	line_h := m.ascent + m.descent + m.line_gap + p.line_spacing * em
	para_gap := p.paragraph_spacing * em
	char_gap := p.character_spacing * em
	if .Bold in p.style do char_gap += BOLD_SPACING * em
	word_gap := p.word_spacing * em

	// Runes after the case transform, with the size each one draws at.
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	sizes := make([dynamic]f32, 0, len(text), context.temp_allocator)
	for r in text {
		rr, sz := _styled_rune(r, p.style, p.size)
		append(&runes, rr)
		append(&sizes, sz)
	}
	n := len(runes)

	// Per rune: the pen shift after it (advance plus spacing) and the kerning
	// shift before it.
	adv := make([]f32, n, context.temp_allocator)
	kern := make([]f32, n, context.temp_allocator)
	for r, i in runes {
		if r == '\n' do continue
		if r == '\t' {
			if sp, sok := b.glyph(p.font, sizes[i], ' '); sok do adv[i] = TAB_SPACES * (sp.advance + char_gap)
			continue
		}
		g, gok := b.glyph(p.font, sizes[i], r)
		if !gok do continue
		adv[i] = g.advance + char_gap
		if r == ' ' do adv[i] += word_gap
		if p.kerning && i > 0 && runes[i - 1] != '\n' && b.kern != nil do kern[i] = b.kern(p.font, sizes[i], runes[i - 1], r)
	}

	// Lines: greedy word wrap on spaces, hard breaks on '\n'.
	lines := make([dynamic]_Line, context.temp_allocator)
	start := 0
	for start <= n {
		end := start
		width := f32(0)
		spaces := 0
		last_space := -1
		width_at_space := f32(0)
		spaces_at_space := 0
		for end < n && runes[end] != '\n' {
			w := adv[end] + kern[end]
			if p.wrap && width + w - char_gap > rect.size.x && end > start {
				if last_space >= 0 {
					// Back up to the space; the line ends before it.
					end = last_space
					width = width_at_space
					spaces = spaces_at_space
				}
				break
			}
			if runes[end] == ' ' {
				last_space = end
				width_at_space = width
				spaces_at_space = spaces
				spaces += 1
			}
			width += w
			end += 1
		}
		if end > start do width -= char_gap // no spacing after the last glyph
		append(&lines, _Line{first = start, last = end, width = width, spaces = spaces, hard = end >= n || runes[end] == '\n'})
		if end >= n do break
		// Skip the break character (the '\n', or the space we wrapped at).
		start = end + 1
		if start > n do break
	}
	if len(lines) == 0 do return res

	// Block height with paragraph gaps after every hard line but the last.
	block_height :: proc(lines: []_Line, line_h, para_gap: f32) -> f32 {
		h := f32(len(lines)) * line_h
		for l, i in lines do if l.hard && i + 1 < len(lines) do h += para_gap
		return h
	}
	for l in lines do if l.width > rect.size.x + 0.01 do res.overflow = true
	if block_height(lines[:], line_h, para_gap) > rect.size.y + 0.01 do res.overflow = true

	// Ellipsis and Truncate: keep the lines that fit (at least one), then cut
	// each kept line at the rect's width. The ellipsis takes the room of "...".
	if p.overflow == .Ellipsis || p.overflow == .Truncate {
		kept := len(lines)
		for kept > 1 && block_height(lines[:kept], line_h, para_gap) > rect.size.y + 0.01 do kept -= 1
		cut_lines := kept < len(lines)
		resize(&lines, kept)
		dots_w := f32(0)
		if p.overflow == .Ellipsis {
			if dot, dok := b.glyph(p.font, p.size, '.'); dok do dots_w = 3 * (dot.advance + char_gap)
		}
		for &l, li in lines {
			wants_dots := p.overflow == .Ellipsis && (l.width > rect.size.x + 0.01 || (cut_lines && li == kept - 1))
			limit := rect.size.x - (dots_w if wants_dots else 0)
			if l.width > limit + 0.01 {
				for l.last > l.first && l.width > limit + 0.01 {
					l.last -= 1
					l.width -= adv[l.last] + kern[l.last]
					if runes[l.last] == ' ' do l.spaces -= 1
				}
				// The spacing the dropped glyph carried is gone as well.
				if l.last > l.first do l.width = _line_width(l, adv, kern, char_gap)
			}
			l.ellipsis = wants_dots
		}
	}

	// The block's top edge.
	block_h := block_height(lines[:], line_h, para_gap)
	center := rect.pos.y + rect.size.y * 0.5
	top: f32
	switch p.vertical {
	case .Top:      top = rect.pos.y + rect.size.y
	case .Middle:   top = center + block_h * 0.5
	case .Bottom:   top = rect.pos.y + block_h
	case .Baseline: top = center + m.ascent
	case .Midline:  top = center + (m.ascent + m.descent) * 0.5
	case .Capline:  top = center + m.ascent * (1 - CAP_HEIGHT)
	}

	y_top := top
	for line in lines {
		baseline := y_top - m.ascent
		pen := rect.pos.x
		#partial switch p.horizontal {
		case .Center: pen += (rect.size.x - line.width) * 0.5
		case .Right:  pen += rect.size.x - line.width
		}
		// Justification spreads the slack over the spaces, or over the gaps
		// between glyphs on a line without spaces.
		per_space, per_gap: f32
		justify := p.horizontal == .Flush || (p.horizontal == .Justified && !line.hard)
		if justify && line.width < rect.size.x && !line.ellipsis {
			slack := rect.size.x - line.width
			if line.spaces > 0 {
				per_space = slack / f32(line.spaces)
			} else if line.last - line.first > 1 {
				per_gap = slack / f32(line.last - line.first - 1)
			}
		}
		x0 := pen
		for i in line.first ..< line.last {
			r := runes[i]
			pen += kern[i]
			if r != '\t' {
				if g, gok := b.glyph(p.font, sizes[i], r); gok do _emit_glyph(out, g, pen, baseline, p.style, sizes[i])
			}
			pen += adv[i]
			if r == ' ' do pen += per_space
			if i + 1 < line.last do pen += per_gap
		}
		if line.ellipsis {
			if dot, dok := b.glyph(p.font, p.size, '.'); dok {
				for _ in 0 ..< 3 {
					_emit_glyph(out, dot, pen, baseline, p.style, p.size)
					pen += dot.advance + char_gap
				}
			}
		}
		x1 := pen - char_gap
		if .Underline in p.style do _emit_rule(out, b, p, x0, x1, baseline, false, m)
		if .Strikethrough in p.style do _emit_rule(out, b, p, x0, x1, baseline, true, m)
		y_top -= line_h
		if line.hard do y_top -= para_gap
	}

	if p.overflow == .Masking {
		for i := base; i < len(out); {
			if _clip_quad(&out[i], rect) {
				i += 1
			} else {
				ordered_remove(out, i)
			}
		}
	}
	return res
}

@(private = "file")
_line_width :: proc(l: _Line, adv, kern: []f32, char_gap: f32) -> f32 {
	w := f32(0)
	for i in l.first ..< l.last do w += adv[i] + kern[i]
	return w - char_gap
}

@(private = "file")
_styled_rune :: proc(r: rune, style: Font_Style, size: f32) -> (rune, f32) {
	if .Uppercase in style do return unicode.to_upper(r), size
	if .Lowercase in style do return unicode.to_lower(r), size
	if .Smallcaps in style && unicode.is_lower(r) do return unicode.to_upper(r), size * SMALLCAPS_SCALE
	return r, size
}

// One glyph at the pen; a second copy under Bold.
@(private = "file")
_emit_glyph :: proc(out: ^[dynamic]Glyph_Quad, g: Glyph, pen, baseline: f32, style: Font_Style, size: f32) {
	if g.size.x <= 0 || g.size.y <= 0 do return
	q := Glyph_Quad{pos = {pen + g.offset.x, baseline + g.offset.y}, size = g.size, uvs = g.uvs, texture = g.texture}
	if .Italic in style {
		bottom := q.pos.y - baseline
		q.skew = {bottom * ITALIC_SHEAR, (bottom + q.size.y) * ITALIC_SHEAR}
	}
	append(out, q)
	if .Bold in style {
		q.pos.x += size * BOLD_OFFSET
		append(out, q)
	}
}

// A slab from x0 to x1 built from the '_' glyph: its center column of the
// field stretched, so the slab has the underscore's thickness and edges.
// Underline sits where the underscore sits; strikethrough is centered at
// STRIKETHROUGH_HEIGHT of the ascent.
@(private = "file")
_emit_rule :: proc(out: ^[dynamic]Glyph_Quad, b: ^Backend, p: Layout_Params, x0, x1, baseline: f32, strike: bool, m: Line_Metrics) {
	if x1 <= x0 do return
	g, ok := b.glyph(p.font, p.size, '_')
	if !ok || g.size.y <= 0 do return
	u := (g.uvs[0].x + g.uvs[1].x) * 0.5
	uvs := g.uvs
	for &uv in uvs do uv.x = u
	y := baseline + g.offset.y
	if strike do y = baseline + m.ascent * STRIKETHROUGH_HEIGHT - g.size.y * 0.5
	append(out, Glyph_Quad{pos = {x0, y}, size = {x1 - x0, g.size.y}, uvs = uvs, texture = g.texture})
}

// Cuts the quad to the rect, moving its uvs along; false when nothing is
// left. The skew is kept as is.
@(private = "file")
_clip_quad :: proc(q: ^Glyph_Quad, r: engine.Rect) -> bool {
	x0 := max(q.pos.x, r.pos.x)
	y0 := max(q.pos.y, r.pos.y)
	x1 := min(q.pos.x + q.size.x, r.pos.x + r.size.x)
	y1 := min(q.pos.y + q.size.y, r.pos.y + r.size.y)
	if x1 <= x0 || y1 <= y0 do return false
	fx0 := (x0 - q.pos.x) / q.size.x
	fx1 := (x1 - q.pos.x) / q.size.x
	fy0 := (y0 - q.pos.y) / q.size.y
	fy1 := (y1 - q.pos.y) / q.size.y
	uv_at :: proc(uvs: [4][2]f32, fx, fy: f32) -> [2]f32 {
		bottom := uvs[0] + (uvs[1] - uvs[0]) * fx
		top := uvs[3] + (uvs[2] - uvs[3]) * fx
		return bottom + (top - bottom) * fy
	}
	q.uvs = {uv_at(q.uvs, fx0, fy0), uv_at(q.uvs, fx1, fy0), uv_at(q.uvs, fx1, fy1), uv_at(q.uvs, fx0, fy1)}
	q.pos = {x0, y0}
	q.size = {x1 - x0, y1 - y0}
	return true
}
