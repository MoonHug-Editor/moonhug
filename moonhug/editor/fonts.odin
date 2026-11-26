package editor

import im "moonhug:external/odin-imgui"
import "core:math"
import "moonhug:editor/icons"
import "moonhug:editor/handles"
import "moonhug:editor/widgets"

// Roboto Medium (shipped with imgui under misc/fonts, Apache-2.0) is the base
// UI font. 15px is the size imgui's own font notes recommend for it on a 1x
// display and matches the x-height of the old 13px ProggyClean rows.
FONT_SIZE :: widgets.FONT_SIZE

ROBOTO_FONT_DATA := #load("moonhug:external/odin-imgui/imgui/misc/fonts/Roboto-Medium.ttf")

// Roboto Light (moonhug/external/fonts/roboto, Apache-2.0): the inspectors'
// row text. Header names stay in the base Medium, which sets the headers
// apart from the rows under them.
ROBOTO_LIGHT_FONT_DATA := #load("moonhug:external/fonts/roboto/Roboto-Light.ttf")

// How much the Light font's glyph coverage is raised. Thin strokes cover less
// of each pixel, so at the same text color they read as a lighter grey than
// the Medium beside them: this brings them back to the same ink.
ROBOTO_LIGHT_INK :: f32(1.75)

// Large Material-icon font size for spots that show an icon spanning ~2 text
// rows (e.g. the console's per-entry icon column, Unity-style).
ICON_FONT_SIZE_LG :: 26

// Standalone (non-merged) large Material icon font. Push it around a single
// icon glyph, then pop back. Set by editor_fonts_init.
editor_icon_font_lg: ^im.Font

// Material Symbols Outlined, embedded at compile time so the editor is
// independent of the runtime working directory (#load path resolves through the
// `moonhug` collection). License: Apache-2.0 (see moonhug/external/fonts/material).
MATERIAL_FONT_DATA := #load("moonhug:external/fonts/material/MaterialSymbolsOutlined.ttf")

// A VALID FontConfig at an EXPLICIT reference size. Odin zero-inits, but imgui
// 1.92's rasterizer relies on several non-zero ctor defaults — missing any bakes
// INVISIBLE glyphs (no assert). ExtraSizeScale is the sneaky one (0 => zero glyph
// size). An explicit SizePixels (vs the implicit-size default font) is what lets
// the merged icon font use GlyphOffset for baseline alignment.
@(private = "file")
_font_config :: proc(size_px: f32 = FONT_SIZE) -> im.FontConfig {
	cfg: im.FontConfig
	cfg.OversampleH = 0
	cfg.OversampleV = 0
	cfg.RasterizerMultiply = 1.0
	cfg.RasterizerDensity = 1.0
	cfg.ExtraSizeScale = 1.0            // 0 => invisible glyphs
	cfg.GlyphMaxAdvanceX = math.F32_MAX // ctor default (FLT_MAX)
	cfg.SizePixels = size_px            // explicit ref size
	return cfg
}

// One text font from `data` at FONT_SIZE, with the Material icons merged into
// it, so a label that mixes text and an icon draws under any of them. `ink`
// raises the text glyphs' coverage (the icons keep theirs).
@(private = "file")
_add_text_font :: proc(data: []byte, ink: f32 = 1) -> ^im.Font {
	fonts := im.GetIO().Fonts
	// At an EXPLICIT size (config with SizePixels > 0 keeps it explicit-size,
	// so the icon merge below can use GlyphOffset). The config must be fully
	// defaulted or text bakes invisible.
	base_cfg := _font_config()
	base_cfg.FontDataOwnedByAtlas = false // static (#load) data; imgui must not free
	base_cfg.RasterizerMultiply = ink
	font := im.FontAtlas_AddFontFromMemoryTTF(fonts, raw_data(data), i32(len(data)), FONT_SIZE, &base_cfg)

	// Merge Material icons into it at the same explicit size. GlyphOffset
	// nudges the icons down onto the text baseline (Material's em box is
	// taller than Roboto's).
	@(static) icon_ranges := [?]im.Wchar{ icons.ICON_MD_MIN, icons.ICON_MD_MAX, 0 }
	icon_cfg := _font_config()
	icon_cfg.MergeMode = true
	icon_cfg.PixelSnapH = true
	icon_cfg.GlyphMinAdvanceX = FONT_SIZE
	icon_cfg.GlyphOffset = im.Vec2{0, 2}
	icon_cfg.FontDataOwnedByAtlas = false // static (#load) data; imgui must not free
	im.FontAtlas_AddFontFromMemoryTTF(fonts, raw_data(MATERIAL_FONT_DATA), i32(len(MATERIAL_FONT_DATA)), FONT_SIZE, &icon_cfg, &icon_ranges[0])
	return font
}

// Load editor UI fonts: Roboto Medium at FONT_SIZE with Material Symbols icons
// merged into it. Call once after im.CreateContext() and before the first
// NewFrame / backend texture build. The backend advertises RendererHasTextures,
// so the atlas builds lazily.
editor_fonts_init :: proc() {
	fonts := im.GetIO().Fonts

	// The base UI font first: imgui's default font is the first one added.
	widgets.font_headers = _add_text_font(ROBOTO_FONT_DATA)
	widgets.font_rows = _add_text_font(ROBOTO_LIGHT_FONT_DATA, ROBOTO_LIGHT_INK)
	icon_ranges := [?]im.Wchar{ icons.ICON_MD_MIN, icons.ICON_MD_MAX, 0 }
	// Scene icons draw Material Symbols glyphs from the same static data
	// (editor/handles/icons.odin).
	handles.icon_font_set(MATERIAL_FONT_DATA)

	// Standalone large icon font (NOT merged) for the console's 2-row icon
	// column. Same range, no GlyphOffset — it's drawn on its own, centered by
	// the caller. FontDataOwnedByAtlas=false: shares the static #load buffer.
	lg_cfg := _font_config(ICON_FONT_SIZE_LG)
	lg_cfg.PixelSnapH = true
	lg_cfg.GlyphMinAdvanceX = ICON_FONT_SIZE_LG
	lg_cfg.FontDataOwnedByAtlas = false
	editor_icon_font_lg = im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(MATERIAL_FONT_DATA),
		i32(len(MATERIAL_FONT_DATA)),
		ICON_FONT_SIZE_LG,
		&lg_cfg,
		&icon_ranges[0],
	)
	widgets.dialog_icon_font = editor_icon_font_lg
	widgets.icon_font_lg = editor_icon_font_lg
}
