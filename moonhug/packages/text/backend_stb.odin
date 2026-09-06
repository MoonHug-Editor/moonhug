package text

// The default backend: stb_truetype, bitmap glyphs baked into one atlas per
// (font, size). No import step and no extra dependency — the font file's
// bytes are read straight from the asset path. Glyphs are crisp at their
// baked size and blur when a rect scales them; an SDF or MSDF backend is the
// upgrade path, through the same Backend interface.

import "base:runtime"
import "core:c"
import "core:os"
import "core:encoding/uuid"
import stbtt "vendor:stb/truetype"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"

// Glyph ranges baked per atlas: ASCII and Latin-1 supplement.
_STB_RANGES := [2][2]rune{{32, 126}, {160, 255}}
_STB_CHAR_COUNT :: 95 + 96

_Stb_Face :: struct {
	data:    []u8, // the font file, owned (stb reads it on every call)
	info:    stbtt.fontinfo,
	ok:      bool,
}

_Stb_Atlas :: struct {
	scale:    f32, // stb scale for this pixel size
	metrics:  Line_Metrics,
	chars:    [_STB_CHAR_COUNT]stbtt.packedchar,
	tex_size: [2]f32,
	texture:  engine.Asset_GUID, // registered in engine.texture_cache; empty when headless
}

_Stb_Key :: struct {
	font: engine.Asset_GUID,
	size: i32,
}

_stb_faces:   map[engine.Asset_GUID]_Stb_Face
_stb_atlases: map[_Stb_Key]_Stb_Atlas

// Font file bytes, read once per font.
@(private = "file")
_stb_face :: proc(font: engine.Asset_GUID) -> ^_Stb_Face {
	if f, ok := &_stb_faces[font]; ok do return f
	face: _Stb_Face
	if path, pok := engine.asset_db_get_path(uuid.Identifier(font)); pok {
		// Process heap: stb reads the bytes on every call, for the session.
		if data, rerr := os.read_entire_file(path, runtime.default_allocator()); rerr == nil {
			face.data = data
			face.ok = bool(stbtt.InitFont(&face.info, raw_data(data), 0))
		}
	}
	_stb_faces[font] = face
	return &_stb_faces[font]
}

@(private = "file")
_stb_char_index :: proc(r: rune) -> int {
	if r >= 32 && r <= 126 do return int(r - 32)
	if r >= 160 && r <= 255 do return 95 + int(r - 160)
	return -1
}

// A stable guid for the (font, size) atlas: the font's guid with the size
// folded into its last bytes. Never collides with an asset (fonts are not
// textures) and stays the same across sessions.
@(private = "file")
_stb_atlas_guid :: proc(font: engine.Asset_GUID, size: i32) -> engine.Asset_GUID {
	g := font
	g[12] ~= u8(size)
	g[13] ~= u8(size >> 8)
	g[14] ~= 0xA7
	g[15] ~= 0x1A
	return g
}

// The atlas for a (font, size), baked on first use. Metrics come even when
// there is no GPU (tests, headless), only the texture is skipped.
@(private = "file")
_stb_atlas :: proc(font: engine.Asset_GUID, size_px: f32) -> ^_Stb_Atlas {
	key := _Stb_Key{font, i32(max(size_px, 1) + 0.5)}
	if a, ok := &_stb_atlases[key]; ok do return a
	atlas: _Stb_Atlas
	face := _stb_face(font)
	if !face.ok {
		_stb_atlases[key] = atlas
		return &_stb_atlases[key]
	}
	size := f32(key.size)
	atlas.scale = stbtt.ScaleForPixelHeight(&face.info, size)
	asc, desc, gap: c.int
	stbtt.GetFontVMetrics(&face.info, &asc, &desc, &gap)
	atlas.metrics = {f32(asc) * atlas.scale, f32(-desc) * atlas.scale, f32(gap) * atlas.scale}

	// Pack both ranges; grow the atlas until they fit.
	dims := [3]i32{512, 1024, 2048}
	for dim in dims {
		bitmap := make([]u8, int(dim * dim), context.temp_allocator)
		pc: stbtt.pack_context
		if !stbtt.PackBegin(&pc, raw_data(bitmap), dim, dim, 0, 1, nil) do continue
		fit := true
		offset := 0
		for rg in _STB_RANGES {
			count := int(rg[1] - rg[0] + 1)
			if !stbtt.PackFontRange(&pc, raw_data(face.data), 0, size, c.int(rg[0]), c.int(count), raw_data(atlas.chars[offset:])) {
				fit = false
			}
			offset += count
		}
		stbtt.PackEnd(&pc)
		if !fit do continue
		atlas.tex_size = {f32(dim), f32(dim)}
		if gfx.device() != nil {
			// White glyphs with the coverage as alpha; the text color tints.
			rgba := make([]u8, int(dim * dim * 4), context.temp_allocator)
			for a, i in bitmap {
				rgba[i * 4 + 0] = 255
				rgba[i * 4 + 1] = 255
				rgba[i * 4 + 2] = 255
				rgba[i * 4 + 3] = a
			}
			tex := gfx.texture_create(rgba, dim, dim)
			guid := _stb_atlas_guid(font, key.size)
			engine.texture_cache[guid] = engine.Texture2D{guid = guid, width = dim, height = dim, pixels_per_unit = engine.PIXELS_PER_UNIT, gfx = tex}
			atlas.texture = guid
		}
		break
	}
	_stb_atlases[key] = atlas
	return &_stb_atlases[key]
}

@(private = "file")
_stb_metrics :: proc(font: engine.Asset_GUID, size_px: f32) -> (Line_Metrics, bool) {
	a := _stb_atlas(font, size_px)
	return a.metrics, a.scale > 0
}

@(private = "file")
_stb_glyph :: proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (Glyph, bool) {
	a := _stb_atlas(font, size_px)
	if a.scale <= 0 do return {}, false
	idx := _stb_char_index(r)
	if idx < 0 do idx = _stb_char_index('?')
	pc := a.chars[idx]
	g: Glyph
	g.advance = pc.xadvance
	g.size = {pc.xoff2 - pc.xoff, pc.yoff2 - pc.yoff}
	// stb offsets are y-down from the baseline: the quad's bottom is yoff2.
	g.offset = {pc.xoff, -pc.yoff2}
	u0 := f32(pc.x0) / a.tex_size.x
	u1 := f32(pc.x1) / a.tex_size.x
	v0 := f32(pc.y0) / a.tex_size.y
	v1 := f32(pc.y1) / a.tex_size.y
	g.uvs = {{u0, v1}, {u1, v1}, {u1, v0}, {u0, v0}}
	g.texture = a.texture
	return g, true
}

@(private = "file")
_stb_kern :: proc(font: engine.Asset_GUID, size_px: f32, a, b: rune) -> f32 {
	face := _stb_face(font)
	if !face.ok do return 0
	atlas := _stb_atlas(font, size_px)
	return f32(stbtt.GetCodepointKernAdvance(&face.info, a, b)) * atlas.scale
}

stb_backend :: proc() -> Backend {
	return Backend{name = "stb_truetype", metrics = _stb_metrics, glyph = _stb_glyph, kern = _stb_kern}
}
