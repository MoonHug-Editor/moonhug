package handles

// Scene icons (docs/Handles.md): a clickable marker for components with
// nothing else to click, drawn from an @(on_draw_gizmos) hook for every
// instance, selected or not. An icon is a dark round badge ICON_PX wide
// facing the camera, showing one of:
//
// - a symbol: a proc that draws with engine/gizmos shapes (the built-in
//   icons for lights, cameras and audio sources)
// - a glyph of the editor's icon font, by its Material Symbols codepoint
//   (external/fonts/material/MaterialSymbolsOutlined.codepoints)
// - a texture asset, by its guid
//
// Clicking the badge in the scene view selects its owner, and box select
// takes it too. Icons are gizmos (the .Editor channel), so handles and the
// transform gizmo draw over them, and the game view shows them with its
// Gizmos toggle. Each view draws them facing its own camera (gizmos.icon).

import "base:runtime"
import "core:c"
import "core:fmt"
import stbtt "vendor:stb/truetype"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"
import "moonhug:engine/gizmos"

// An icon's width on screen.
ICON_PX :: f32(28)

// Draws a symbol with engine/gizmos in the badge's space: -1..1 spans the
// badge, +X right and +Y up on screen, in the current color.
Icon_Symbol :: engine.Gizmo_Symbol

// A glyph's texture size in pixels: twice the icon, so it stays sharp on a
// high-density screen.
GLYPH_PX :: 64

// A scene icon at `pos` (in the current space) for `owner`: a symbol, a
// glyph or a texture. `color` tints a symbol or glyph and multiplies a
// texture. An owner inactive in the hierarchy gets none, as it gets no
// picking.
icon :: proc {
	icon_symbol,
	icon_glyph,
	icon_texture,
}

icon_symbol :: proc(pos: [3]f32, owner: engine.Transform_Handle, symbol: Icon_Symbol, color := COLOR_HANDLE) {
	_icon(pos, owner, symbol, color)
}

// `glyph` is a Material Symbols codepoint: '\ue90f' (lightbulb), for example.
icon_glyph :: proc(pos: [3]f32, owner: engine.Transform_Handle, glyph: rune, color := COLOR_HANDLE) {
	_icon(pos, owner, glyph, color)
}

// `texture` is a texture asset's guid (a component field picked in the
// inspector). White keeps its colors.
icon_texture :: proc(pos: [3]f32, owner: engine.Transform_Handle, texture: engine.Asset_GUID, color := [4]f32{1, 1, 1, 1}) {
	_icon(pos, owner, texture, color)
}

@(private = "file")
_icon :: proc(pos: [3]f32, owner: engine.Transform_Handle, image: engine.Gizmo_Icon_Image, color: [4]f32) {
	if !engine.transform_active_in_hierarchy(owner) do return
	gizmos.with_depth_test(false)
	gizmos.icon(pos, ICON_PX, owner, image, color, backdrop = COLOR_SHADOW)
}

// --- Glyphs -------------------------------------------------------------------------

@(private = "file")
_font: stbtt.fontinfo

@(private = "file")
_font_ready: bool

// Textures per glyph, made on first draw. Cross-frame state: never borrows
// the caller's allocator.
@(private = "file")
_glyph_textures: map[rune]^gfx.Texture

// The icon font glyph icons draw with: the editor passes its Material
// Symbols font at startup. `ttf` must outlive the process (the editor's is
// #load data).
icon_font_set :: proc(ttf: []u8) {
	_font_ready = bool(stbtt.InitFont(&_font, raw_data(ttf), 0))
	assert(_font_ready, "handles.icon_font_set: not a font")
	gizmos.set_glyph_source(_glyph_texture)
}

// A glyph's pixels as the icon draws them: `px` square RGBA, white, the
// glyph's coverage in alpha, its box centered. ok=false when the font has no
// such glyph.
glyph_bitmap :: proc(glyph: rune, px: i32, allocator := context.allocator) -> (rgba: []u8, ok: bool) {
	assert(_font_ready, "handles: no icon font (the editor sets one at startup, icon_font_set)")
	if stbtt.FindGlyphIndex(&_font, glyph) == 0 do return nil, false
	scale := stbtt.ScaleForMappingEmToPixels(&_font, f32(px))
	x0, y0, x1, y1: c.int
	stbtt.GetCodepointBitmapBox(&_font, glyph, scale, scale, &x0, &y0, &x1, &y1)
	w, h := min(i32(x1 - x0), px), min(i32(y1 - y0), px)
	if w <= 0 || h <= 0 do return nil, false

	alpha := make([]u8, px * px, context.temp_allocator)
	ox, oy := (px - w) / 2, (px - h) / 2
	stbtt.MakeCodepointBitmap(&_font, &alpha[oy * px + ox], c.int(w), c.int(h), c.int(px), scale, scale, glyph)
	rgba = make([]u8, px * px * 4, allocator)
	for a, i in alpha {
		rgba[i * 4 + 0] = 255
		rgba[i * 4 + 1] = 255
		rgba[i * 4 + 2] = 255
		rgba[i * 4 + 3] = a
	}
	return rgba, true
}

// The glyph source gizmos draws glyph icons with. A codepoint the font does
// not have is a bug in the caller: it fails loudly.
@(private = "file")
_glyph_texture :: proc(glyph: rune) -> ^gfx.Texture {
	if tex, ok := _glyph_textures[glyph]; ok do return tex
	context.allocator = runtime.default_allocator()
	rgba, ok := glyph_bitmap(glyph, GLYPH_PX, context.temp_allocator)
	fmt.assertf(ok, "handles.icon: U+%04X is not in the icon font", glyph)
	tex := gfx.texture_create(rgba, GLYPH_PX, GLYPH_PX)
	_glyph_textures[glyph] = tex
	return tex
}
