package text

// Line breaking, alignment, styles and overflow, backend-neutral: the backend
// supplies advances and metrics, this turns a string and a rect into glyph
// quads in canvas units. Pure, so the tests drive it with a fake backend.

import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "moonhug:packages/engine"

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
	// Rich text: the glyph has a colour of its own, from a <color> tag.
	color:   [4]f32,
	colored: bool,
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
	rich:              bool, // tags in the text set the style, the size and the colour of spans (rich_parse)
}

Layout_Result :: struct {
	ok:       bool, // the backend serves the font
	overflow: bool, // a line is wider than the rect or the block is taller, before any cut
	size:     [2]f32, // the widest line and the block's height, before any cut
}

// Where a text caret stands before one rune of a laid out string, or after
// the last one: `pos` is the foot of the caret, on the line's bottom edge,
// and `height` runs up to the line's top. `line` counts from 0 at the top.
// layout_text gives one per rune and one for the end, so a string of n runes
// has n + 1.
Caret :: struct {
	pos:    [2]f32,
	height: f32,
	line:   int,
}

@(private = "file")
_Line :: struct {
	first, last: int, // rune indices, [first, last)
	width:       f32,
	spaces:      int,  // spaces inside the line, for justification
	hard:        bool, // ends a paragraph: a '\n' or the end of the text
	ellipsis:    bool, // draws "..." after its last glyph
	// The line's own metrics: those of the largest size on it.
	ascent, descent, height: f32,
}

// Lays `text` out inside `rect`, appending one Glyph_Quad per visible glyph
// (two under Bold, plus one slab per line for Underline and Strikethrough).
// Lines break at '\n', and when `p.wrap` is set also at spaces once a line
// would pass the rect's width (a single word wider than the rect stays on its
// own line). A '\t' advances TAB_SPACES spaces.
//
// `carets`, when given, gets a Caret per rune of the text and one for its
// end (the runes of the string as passed, before any case style). An empty
// string has the one caret where its first glyph would start. A rune on a
// line that an overflow mode cut away has the caret of the last line kept.
layout_text :: proc(b: ^Backend, p: Layout_Params, text: string, rect: engine.Rect, out: ^[dynamic]Glyph_Quad, carets: ^[dynamic]Caret = nil) -> Layout_Result {
	if b.metrics == nil || b.glyph == nil do return {}
	m, ok := b.metrics(p.font, p.size)
	if !ok do return {}
	res := Layout_Result{ok = true}
	if text == "" && carets == nil do return res
	base := len(out)
	em := p.size * 0.01
	line_h := m.ascent + m.descent + m.line_gap + p.line_spacing * em
	para_gap := p.paragraph_spacing * em
	char_gap := p.character_spacing * em
	if .Bold in p.style do char_gap += BOLD_SPACING * em
	word_gap := p.word_spacing * em

	// Runes after the case transform, with the size, the style and the
	// colour each one draws with: the Text's own, or a span's under rich text.
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	sizes := make([dynamic]f32, 0, len(text), context.temp_allocator)
	spans := make([dynamic]Rich_Span, 0, len(text), context.temp_allocator)
	if p.rich {
		rich_parse(text, p.style, p.size, &runes, &spans)
	} else {
		for r in text {
			append(&runes, r)
			append(&spans, Rich_Span{style = p.style, size = p.size})
		}
	}
	for r, i in runes {
		rr, sz := _styled_rune(r, spans[i].style, spans[i].size)
		runes[i] = rr
		append(&sizes, sz)
	}
	n := len(runes)
	caret_base := 0
	if carets != nil {
		caret_base = len(carets)
		resize(carets, caret_base + n + 1)
	}
	carets_set := 0 // how many carets, from the first, have their place

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
		// A bold span in a Text that is not bold has the bold spacing too.
		if .Bold in spans[i].style && .Bold not_in p.style do adv[i] += BOLD_SPACING * spans[i].size * 0.01
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

	// Each line's metrics. Under rich text a line is as tall as the largest
	// size on it needs.
	for &l in lines {
		lm := m
		if p.rich {
			size := f32(0)
			for i in l.first ..< l.last do size = max(size, spans[i].size)
			if size > 0 && size != p.size {
				if own, own_ok := b.metrics(p.font, size); own_ok do lm = own
			}
		}
		l.ascent, l.descent = lm.ascent, lm.descent
		l.height = lm.ascent + lm.descent + lm.line_gap + p.line_spacing * em
	}
	// Block height with paragraph gaps after every hard line but the last.
	// `line_h` over 0 says every line has that height.
	block_height :: proc(lines: []_Line, line_h, para_gap: f32) -> f32 {
		h := f32(len(lines)) * line_h
		if line_h <= 0 do for l in lines do h += l.height
		for l, i in lines do if l.hard && i + 1 < len(lines) do h += para_gap
		return h
	}
	if p.rich do line_h = 0
	for l in lines {
		if l.width > rect.size.x + 0.01 do res.overflow = true
		res.size.x = max(res.size.x, l.width)
	}
	res.size.y = block_height(lines[:], line_h, para_gap)
	if res.size.y > rect.size.y + 0.01 do res.overflow = true

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

	// Where each rune starts and ends along its line, for the rules.
	starts := make([]f32, n, context.temp_allocator)
	ends := make([]f32, n, context.temp_allocator)
	y_top := top
	for line, line_index in lines {
		baseline := y_top - line.ascent
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
		line_bottom := y_top - (line.ascent + line.descent)
		line_tall := line.ascent + line.descent
		for i in line.first ..< line.last {
			r := runes[i]
			if carets != nil do carets[caret_base + i] = Caret{{pen, line_bottom}, line_tall, line_index}
			starts[i] = pen
			pen += kern[i]
			if r != '\t' {
				if g, gok := b.glyph(p.font, sizes[i], r); gok do _emit_glyph(out, g, pen, baseline, spans[i], sizes[i])
			}
			pen += adv[i]
			if r == ' ' do pen += per_space
			if i + 1 < line.last do pen += per_gap
			ends[i] = pen - char_gap
		}
		if line.ellipsis {
			if dot, dok := b.glyph(p.font, p.size, '.'); dok {
				for _ in 0 ..< 3 {
					_emit_glyph(out, dot, pen, baseline, Rich_Span{style = p.style, size = p.size}, p.size)
					pen += dot.advance + char_gap
				}
			}
		}
		x1 := pen - char_gap
		if carets != nil {
			// The line's end: after its last glyph, where the rune that
			// broke it (a '\n', or the space it wrapped at) stands. Runes
			// an overflow mode cut from the line stand there too.
			line_end := Caret{{x1 if line.last > line.first else pen, line_bottom}, line_tall, line_index}
			next_first := lines[line_index + 1].first if line_index + 1 < len(lines) else n + 1
			for i in line.last ..< min(next_first, n + 1) do carets[caret_base + i] = line_end
			carets_set = min(next_first, n + 1)
		}
		// A rule under, or through, each run of runes that has one and shares
		// a colour: the whole line when the Text's own style has it.
		for flag in ([2]Font_Style_Flag{.Underline, .Strikethrough}) {
			for i := line.first; i < line.last; {
				if !(flag in spans[i].style) {
					i += 1
					continue
				}
				j := i
				for j + 1 < line.last && (flag in spans[j + 1].style) && spans[j + 1].colored == spans[i].colored && spans[j + 1].color == spans[i].color do j += 1
				from := x0 if i == line.first else starts[i]
				to := x1 if j == line.last - 1 else ends[j]
				_emit_rule(out, b, p, from, to, baseline, flag == .Strikethrough, line.ascent, spans[i])
				i = j + 1
			}
		}
		y_top -= line.height
		if line.hard do y_top -= para_gap
	}

	// Runes on lines that were cut away.
	if carets != nil && carets_set > 0 {
		for i in carets_set ..< n + 1 do carets[caret_base + i] = carets[caret_base + carets_set - 1]
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
_emit_glyph :: proc(out: ^[dynamic]Glyph_Quad, g: Glyph, pen, baseline: f32, span: Rich_Span, size: f32) {
	if g.size.x <= 0 || g.size.y <= 0 do return
	style := span.style
	q := Glyph_Quad{pos = {pen + g.offset.x, baseline + g.offset.y}, size = g.size, uvs = g.uvs, texture = g.texture, color = span.color, colored = span.colored}
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
_emit_rule :: proc(out: ^[dynamic]Glyph_Quad, b: ^Backend, p: Layout_Params, x0, x1, baseline: f32, strike: bool, ascent: f32, span: Rich_Span) {
	if x1 <= x0 do return
	g, ok := b.glyph(p.font, p.size, '_')
	if !ok || g.size.y <= 0 do return
	u := (g.uvs[0].x + g.uvs[1].x) * 0.5
	uvs := g.uvs
	for &uv in uvs do uv.x = u
	y := baseline + g.offset.y
	if strike do y = baseline + ascent * STRIKETHROUGH_HEIGHT - g.size.y * 0.5
	append(out, Glyph_Quad{pos = {x0, y}, size = {x1 - x0, g.size.y}, uvs = uvs, texture = g.texture, color = span.color, colored = span.colored})
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

// --- Rich text ---------------------------------------------------------------------

// What one rune of a rich text draws with.
Rich_Span :: struct {
	style:   Font_Style,
	size:    f32,
	color:   [4]f32, // with `colored`: the rune's own colour, in place of the Text's
	colored: bool,
}

// How deep <color> and <size> tags nest. A tag past it is ignored.
RICH_DEPTH :: 8

// The longest tag, in bytes between its brackets.
RICH_TAG_MAX :: 40

// Reads a string with tags into its runes and what each draws with. The
// tags, case ignored:
// - <b> <i> <u> <s>: bold, italic, underline, strikethrough, until </b> ...
// - <color=#rgb>, <color=#rrggbb>, <color=#rrggbbaa> or <color=name>, until
//   </color>. The names are in RICH_COLORS.
// - <size=24> (canvas units), <size=150%> (of the Text's size) or <size=+4>
//   and <size=-4> (added to the size around it), until </size>.
// Tags nest, and a closing tag ends the nearest open one of its kind. What
// is in brackets and is no tag stays in the text, brackets and all.
rich_parse :: proc(text: string, style: Font_Style, size: f32, runes: ^[dynamic]rune, spans: ^[dynamic]Rich_Span) {
	State :: struct {
		open:   [Font_Style_Flag]int, // how many tags of each style are open
		sizes:  [RICH_DEPTH]f32,
		colors: [RICH_DEPTH][4]f32,
		size_n, color_n: int,
	}
	st: State
	tag :: proc(st: ^State, raw: string, base_size: f32) -> bool {
		// A tag starts right after its bracket: "a < b > c" is a comparison.
		if raw == "" || raw[0] == ' ' || raw[len(raw) - 1] == ' ' do return false
		t := strings.to_lower(raw, context.temp_allocator)
		flag :: proc(st: ^State, f: Font_Style_Flag, close: bool) -> bool {
			if close {
				if st.open[f] > 0 do st.open[f] -= 1
			} else {
				st.open[f] += 1
			}
			return true
		}
		switch t {
		case "b":  return flag(st, .Bold, false)
		case "/b": return flag(st, .Bold, true)
		case "i":  return flag(st, .Italic, false)
		case "/i": return flag(st, .Italic, true)
		case "u":  return flag(st, .Underline, false)
		case "/u": return flag(st, .Underline, true)
		case "s":  return flag(st, .Strikethrough, false)
		case "/s": return flag(st, .Strikethrough, true)
		case "/color":
			if st.color_n > 0 do st.color_n -= 1
			return true
		case "/size":
			if st.size_n > 0 do st.size_n -= 1
			return true
		}
		eq := strings.index_byte(t, '=')
		if eq < 0 do return false
		name := strings.trim_space(t[:eq])
		value := strings.trim(strings.trim_space(t[eq + 1:]), "\"'")
		switch name {
		case "color":
			c, ok := rich_color(value)
			if !ok do return false
			if st.color_n < RICH_DEPTH {
				st.colors[st.color_n] = c
				st.color_n += 1
			}
			return true
		case "size":
			if value == "" do return false
			around := st.sizes[st.size_n - 1] if st.size_n > 0 else base_size
			to: f32
			if strings.has_suffix(value, "%") {
				v, ok := strconv.parse_f32(value[:len(value) - 1])
				if !ok do return false
				to = base_size * v * 0.01
			} else if value[0] == '+' || value[0] == '-' {
				v, ok := strconv.parse_f32(value[1:])
				if !ok do return false
				to = around + (v if value[0] == '+' else -v)
			} else {
				v, ok := strconv.parse_f32(value)
				if !ok do return false
				to = v
			}
			if st.size_n < RICH_DEPTH {
				st.sizes[st.size_n] = clamp(to, 1, 2000)
				st.size_n += 1
			}
			return true
		}
		return false
	}
	for i := 0; i < len(text); {
		if text[i] == '<' {
			end := strings.index_byte(text[i:min(i + RICH_TAG_MAX + 2, len(text))], '>')
			if end > 1 && tag(&st, text[i + 1:i + end], size) {
				i += end + 1
				continue
			}
		}
		r, w := utf8.decode_rune_in_string(text[i:])
		span := Rich_Span{style = style, size = st.sizes[st.size_n - 1] if st.size_n > 0 else size}
		for f in Font_Style_Flag do if st.open[f] > 0 do span.style += {f}
		if st.color_n > 0 {
			span.color = st.colors[st.color_n - 1]
			span.colored = true
		}
		append(runes, r)
		append(spans, span)
		i += w
	}
}

// The colours a <color=name> tag knows.
RICH_COLORS := [?]struct {
	name:  string,
	color: [4]f32,
}{
	{"white", {1, 1, 1, 1}}, {"black", {0, 0, 0, 1}}, {"red", {1, 0.2, 0.2, 1}}, {"green", {0.2, 0.8, 0.3, 1}},
	{"blue", {0.25, 0.5, 1, 1}}, {"yellow", {1, 0.9, 0.2, 1}}, {"orange", {1, 0.6, 0.15, 1}}, {"purple", {0.65, 0.35, 0.95, 1}},
	{"cyan", {0.2, 0.9, 0.95, 1}}, {"magenta", {1, 0.3, 0.85, 1}}, {"grey", {0.5, 0.5, 0.5, 1}}, {"gray", {0.5, 0.5, 0.5, 1}},
}

// A colour from a tag's value: #rgb, #rrggbb, #rrggbbaa or a name.
rich_color :: proc(value: string) -> (c: [4]f32, ok: bool) {
	if strings.has_prefix(value, "#") {
		hex := value[1:]
		digit :: proc(b: u8) -> (int, bool) {
			switch b {
			case '0' ..= '9': return int(b - '0'), true
			case 'a' ..= 'f': return int(b - 'a') + 10, true
			case 'A' ..= 'F': return int(b - 'A') + 10, true
			}
			return 0, false
		}
		c = {0, 0, 0, 1}
		switch len(hex) {
		case 3:
			for k in 0 ..< 3 {
				d := digit(hex[k]) or_return
				c[k] = f32(d * 17) / 255
			}
			return c, true
		case 6, 8:
			for k in 0 ..< len(hex) / 2 {
				hi := digit(hex[k * 2]) or_return
				lo := digit(hex[k * 2 + 1]) or_return
				c[k] = f32(hi * 16 + lo) / 255
			}
			return c, true
		}
		return {}, false
	}
	for entry in RICH_COLORS do if entry.name == value do return entry.color, true
	return {}, false
}

// A rich text's string with its tags taken out: what shows. Temp-allocated.
rich_plain :: proc(text: string, allocator := context.temp_allocator) -> string {
	runes := make([dynamic]rune, context.temp_allocator)
	spans := make([dynamic]Rich_Span, context.temp_allocator)
	rich_parse(text, {}, 12, &runes, &spans)
	return utf8.runes_to_string(runes[:], allocator)
}
