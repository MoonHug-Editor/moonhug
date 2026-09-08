package text

// The font backend: what a swappable rasterizer provides. Everything above
// it (lines, wrapping, alignment, the collector) is backend-neutral. A
// backend answers three questions for a font at a pixel size: line metrics,
// one glyph, and the kerning between two glyphs. Glyph pixels live in a
// texture the backend registers in engine.texture_cache under a guid of its
// own making, so the renderer draws them like any other quad.
//
// The default is the SDF font (font.odin, sdf_backend). Another package
// replaces it with backend_set at an init phase that runs AFTER this
// package's (ImportersInit order > 2), and the rest of the plugin is
// unchanged: the tests drive layout through a fake monospace backend.

import "moonhug:engine"

// Line metrics in canvas units for a font at a size. All positive:
// `descent` is how far below the baseline glyphs reach.
Line_Metrics :: struct {
	ascent:   f32,
	descent:  f32,
	line_gap: f32,
}

// One glyph at a size. `offset` is the quad's bottom-left relative to the
// pen on the baseline, y up. A glyph with zero size (space) still advances.
Glyph :: struct {
	advance: f32,
	size:    [2]f32,
	offset:  [2]f32,
	uvs:     [4][2]f32, // bl, br, tr, tl
	texture: engine.Asset_GUID,
}

Backend :: struct {
	name:    string,
	metrics: proc(font: engine.Asset_GUID, size_px: f32) -> (Line_Metrics, bool),
	glyph:   proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (Glyph, bool),
	kern:    proc(font: engine.Asset_GUID, size_px: f32, a, b: rune) -> f32,
}

_backend: Backend

backend_set :: proc(b: Backend) {
	_backend = b
}

backend :: proc() -> ^Backend {
	return &_backend
}
