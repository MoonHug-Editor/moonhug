package text

// Line breaking and alignment, backend-neutral: the backend supplies
// advances and metrics, this turns a string and a rect into glyph quads in
// canvas units. Pure, so the tests drive it with a fake backend.

import "moonhug:engine"

// Where the text block sits inside the rect, and how lines align.
Text_Anchor :: enum u8 {
	Upper_Left, Upper_Center, Upper_Right,
	Middle_Left, Middle_Center, Middle_Right,
	Lower_Left, Lower_Center, Lower_Right,
}

// One glyph placed in canvas units: `pos` is the quad's bottom-left.
Glyph_Quad :: struct {
	pos:     [2]f32,
	size:    [2]f32,
	uvs:     [4][2]f32,
	texture: engine.Asset_GUID,
}

@(private = "file")
_Line :: struct {
	first, last: int, // rune indices, [first, last)
	width:       f32,
}

// Lays `text` out inside `rect`, appending one Glyph_Quad per visible glyph.
// Lines break at '\n', and when `wrap` is set also at spaces once a line
// would pass the rect's width (a single word wider than the rect stays on
// its own line). Returns false when the backend cannot serve the font.
layout_text :: proc(b: ^Backend, font: engine.Asset_GUID, size: f32, text: string, rect: engine.Rect, anchor: Text_Anchor, wrap: bool, line_spacing: f32, out: ^[dynamic]Glyph_Quad) -> bool {
	if b.metrics == nil || b.glyph == nil || text == "" do return false
	m, ok := b.metrics(font, size)
	if !ok do return false
	line_h := (m.ascent + m.descent + m.line_gap) * max(line_spacing, 0.01)

	// Runes with the advance each one adds (kerning against its predecessor).
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	for r in text do append(&runes, r)
	n := len(runes)
	adv := make([]f32, n, context.temp_allocator)
	for r, i in runes {
		if r == '\n' do continue
		g, gok := b.glyph(font, size, r)
		if !gok do continue
		adv[i] = g.advance
		if i > 0 && runes[i - 1] != '\n' && b.kern != nil do adv[i] += b.kern(font, size, runes[i - 1], r)
	}

	// Lines: greedy word wrap on spaces, hard breaks on '\n'.
	lines := make([dynamic]_Line, context.temp_allocator)
	start := 0
	for start <= n {
		end := start
		width := f32(0)
		last_space := -1
		width_at_space := f32(0)
		for end < n && runes[end] != '\n' {
			w := adv[end]
			if wrap && width + w > rect.size.x && end > start {
				if last_space >= 0 {
					// Back up to the space; the line ends before it.
					end = last_space
					width = width_at_space
				}
				break
			}
			if runes[end] == ' ' {
				last_space = end
				width_at_space = width
			}
			width += w
			end += 1
		}
		append(&lines, _Line{start, end, width})
		if end >= n do break
		// Skip the break character (the '\n', or the space we wrapped at).
		start = end + 1
		if start > n do break
	}
	if len(lines) == 0 do return true

	// Vertical placement of the block, then each line's horizontal offset.
	row := int(anchor) / 3 // 0 upper, 1 middle, 2 lower
	col := int(anchor) % 3 // 0 left, 1 center, 2 right
	block_h := f32(len(lines)) * line_h
	top := rect.pos.y + rect.size.y - (rect.size.y - block_h) * f32(row) * 0.5
	for line, li in lines {
		baseline := top - m.ascent - f32(li) * line_h
		pen := rect.pos.x + (rect.size.x - line.width) * f32(col) * 0.5
		for i in line.first ..< line.last {
			r := runes[i]
			if i > line.first && b.kern != nil do pen += b.kern(font, size, runes[i - 1], r)
			g, gok := b.glyph(font, size, r)
			if !gok do continue
			if g.size.x > 0 && g.size.y > 0 {
				append(out, Glyph_Quad{
					pos     = {pen + g.offset.x, baseline + g.offset.y},
					size    = g.size,
					uvs     = g.uvs,
					texture = g.texture,
				})
			}
			pen += g.advance
		}
	}
	return true
}
