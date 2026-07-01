package editor

import im "../../external/odin-imgui"
import "core:math"

// ProggyClean (imgui's built-in default) is a bitmap font designed for 13px.
// Using its native size keeps the crisp original look.
FONT_SIZE :: 13

// Material Symbols Outlined, embedded at compile time so the editor is
// independent of the runtime working directory (#load path is relative to this
// source file). License: Apache-2.0 (see external/fonts/material).
MATERIAL_FONT_DATA := #load("../../external/fonts/material/MaterialSymbolsOutlined.ttf")

// A VALID FontConfig at an EXPLICIT reference size. Odin zero-inits, but imgui
// 1.92's rasterizer relies on several non-zero ctor defaults — missing any bakes
// INVISIBLE glyphs (no assert). ExtraSizeScale is the sneaky one (0 => zero glyph
// size). An explicit SizePixels (vs the implicit-size default font) is what lets
// the merged icon font use GlyphOffset for baseline alignment.
@(private = "file")
_font_config :: proc() -> im.FontConfig {
	cfg: im.FontConfig
	cfg.OversampleH = 0
	cfg.OversampleV = 0
	cfg.RasterizerMultiply = 1.0
	cfg.RasterizerDensity = 1.0
	cfg.ExtraSizeScale = 1.0            // 0 => invisible glyphs
	cfg.GlyphMaxAdvanceX = math.F32_MAX // ctor default (FLT_MAX)
	cfg.SizePixels = FONT_SIZE          // explicit ref size
	return cfg
}

// Load editor UI fonts: imgui's built-in ProggyClean (the crisp original text
// look) at its native 13px, with Material Symbols icons merged into it. Call
// once after im.CreateContext() and before the first NewFrame / backend texture
// build. The OpenGL3 backend advertises RendererHasTextures, so the atlas builds
// lazily.
editor_fonts_init :: proc() {
	fonts := im.GetIO().Fonts

	// Base text font: ProggyClean at an EXPLICIT 13px (config with SizePixels > 0
	// keeps it explicit-size, so the icon merge below can use GlyphOffset). The
	// config must be fully defaulted or text bakes invisible.
	base_cfg := _font_config()
	im.FontAtlas_AddFontDefault(fonts, &base_cfg)

	// Merge Material icons into ProggyClean at the same explicit size. GlyphOffset
	// nudges the icons down onto the text baseline (they sit a few px high
	// otherwise, as Material's em box is taller than ProggyClean's).
	icon_ranges := [?]im.Wchar{ ICON_MD_MIN, ICON_MD_MAX, 0 }
	icon_cfg := _font_config()
	icon_cfg.MergeMode = true
	icon_cfg.PixelSnapH = true
	icon_cfg.GlyphMinAdvanceX = FONT_SIZE
	icon_cfg.GlyphOffset = im.Vec2{0, 2}
	icon_cfg.FontDataOwnedByAtlas = false // static (#load) data; imgui must not free
	im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(MATERIAL_FONT_DATA),
		i32(len(MATERIAL_FONT_DATA)),
		FONT_SIZE,
		&icon_cfg,
		&icon_ranges[0],
	)
}
