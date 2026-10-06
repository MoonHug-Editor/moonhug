// Pixel-font text drawn as batched quads — replaces rl.DrawText for the app
// demo menu and doubles as a debug overlay. Draw under a pixel-space ortho:
//
//   set_view_proj(matrix4_ortho_pixels(w, h))
//   debug_text({20, 20}, 16, {1, 1, 1, 1}, "hello")
//
// The glyph texture is a 95x1-cell atlas built lazily from the embedded 8x8
// font (font8x8.odin).
package gfx

_debug_font: ^Texture

_GLYPH_COUNT :: _FONT8X8_LAST - _FONT8X8_FIRST + 1

_debug_font_ensure :: proc() -> ^Texture {
	if _debug_font != nil do return _debug_font
	// One row of 95 glyphs, 8x8 each; white pixels, transparent background.
	w := _GLYPH_COUNT * 8
	h := 8
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for g in 0 ..< _GLYPH_COUNT {
		for row in 0 ..< 8 {
			bits := _font8x8[g][row]
			for col in 0 ..< 8 {
				if bits & (1 << u8(col)) == 0 do continue
				i := (row * w + g * 8 + col) * 4
				pixels[i+0] = 255
				pixels[i+1] = 255
				pixels[i+2] = 255
				pixels[i+3] = 255
			}
		}
	}
	_debug_font = texture_create(pixels, i32(w), i32(h))
	return _debug_font
}

// pos_px is the top-left corner in the current (pixel-ortho) space; size_px
// is the glyph height. Unknown runes render as '?'.
debug_text :: proc(pos_px: [2]f32, size_px: f32, color: [4]f32, text: string) {
	font := _debug_font_ensure()
	if font == nil do return

	cell_u := f32(1) / f32(_GLYPH_COUNT)
	x := pos_px.x
	y := pos_px.y
	for r in text {
		if r == '\n' {
			x = pos_px.x
			y += size_px + size_px * 0.25
			continue
		}
		g := int(r) - _FONT8X8_FIRST
		if g < 0 || g >= _GLYPH_COUNT do g = int('?') - _FONT8X8_FIRST
		u0 := f32(g) * cell_u
		u1 := u0 + cell_u
		// corners: bottom-left, bottom-right, top-right, top-left (y-down space)
		draw_quad(
			{{x, y + size_px, 0}, {x + size_px, y + size_px, 0}, {x + size_px, y, 0}, {x, y, 0}},
			{{u0, 1}, {u1, 1}, {u1, 0}, {u0, 0}},
			color,
			font,
		)
		x += size_px
	}
}

debug_text_width :: proc(size_px: f32, text: string) -> f32 {
	longest, cur := 0, 0
	for r in text {
		if r == '\n' {
			cur = 0
			continue
		}
		cur += 1
		if cur > longest do longest = cur
	}
	return f32(longest) * size_px
}

_debug_text_shutdown :: proc() {
	if _debug_font != nil {
		texture_destroy(_debug_font)
		_debug_font = nil
	}
}
