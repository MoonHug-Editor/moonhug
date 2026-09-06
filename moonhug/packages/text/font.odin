package text

// SDF fonts (docs/Text.md): a font file imports into an artifact holding a
// signed-distance-field atlas plus glyph metrics and kerning, baked once at a
// sampling size and padding. At runtime the atlas becomes a texture and the
// glyph table feeds the layout through a Backend value (backend.odin).

import "base:runtime"
import "core:c"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import stbtt "vendor:stb/truetype"
import stbrp "vendor:stb/rect_pack"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"

// Import settings on a font file (the meta). Baked into the artifact.
@(typ_guid={guid="33026060-aac7-4df7-a6d4-ae9f7b863264", makeProcName=make_pFontSettings})
FontSettings :: struct {
	sampling_size: f32, // glyph height the field is sampled at, px; the shader scales from here
	padding:       i32, // px of distance field around each glyph: the reach of outlines and shadows
	atlas_size:    i32, // atlas side, px; grows in powers of two until the glyphs fit
	latin1:        bool, // bake U+00A0..U+00FF too (ASCII is always baked)
}

make_pFontSettings :: proc() -> any {
	s := new(FontSettings)
	s.sampling_size = 64
	s.padding = 8
	s.atlas_size = 1024
	s.latin1 = true
	return s^
}

// --- Artifact ---------------------------------------------------------------------------------

FONT_MAGIC :: "MHFT"
FONT_VERSION :: u32(1)

Font_Header :: struct #packed {
	magic:       [4]u8,
	version:     u32,
	sampling:    f32, // px
	padding:     f32, // px
	ascent:      f32, // px at sampling size
	descent:     f32, // px, positive
	line_gap:    f32, // px
	atlas_w:     u32,
	atlas_h:     u32,
	glyph_count: u32,
	kern_count:  u32,
}

Font_Glyph :: struct #packed {
	codepoint:      u32,
	x0, y0, x1, y1: u16, // atlas pixels, top-left origin
	xoff, yoff:     f32, // bitmap top-left from the glyph origin on the baseline, y down, px
	advance:        f32, // px
}

Font_Kern :: struct #packed {
	a, b: u32,
	adv:  f32, // px
}

@(private = "file") _RANGES_LATIN1 := [2][2]rune{{32, 126}, {160, 255}}
@(private = "file") _RANGES_ASCII := [1][2]rune{{32, 126}}

@(private = "file")
_bake_ranges :: proc(latin1: bool) -> [][2]rune {
	return _RANGES_LATIN1[:] if latin1 else _RANGES_ASCII[:]
}

// Bakes a font file into the artifact bytes. Pure apart from stb: the tests
// run it headless. Returns ok=false for an unreadable font or an atlas that
// cannot fit even at 4096.
font_bake :: proc(ttf: []u8, s: FontSettings, allocator := context.allocator) -> (artifact: []u8, ok: bool) {
	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(ttf), 0) do return nil, false
	sampling := max(s.sampling_size, 8)
	padding := max(int(s.padding), 1)
	scale := stbtt.ScaleForPixelHeight(&info, sampling)
	asc, desc, gap: c.int
	stbtt.GetFontVMetrics(&info, &asc, &desc, &gap)

	// Every glyph's field bitmap, then one packing pass.
	Baked :: struct {
		cp:      rune,
		bmp:     [^]byte,
		w, h:    c.int,
		xo, yo:  c.int,
		advance: f32,
	}
	baked := make([dynamic]Baked, context.temp_allocator)
	for rg in _bake_ranges(s.latin1) {
		for cp := rg[0]; cp <= rg[1]; cp += 1 {
			b := Baked{cp = cp}
			adv, lsb: c.int
			stbtt.GetCodepointHMetrics(&info, cp, &adv, &lsb)
			b.advance = f32(adv) * scale
			// 128 on the edge, the field spanning `padding` px each way.
			b.bmp = stbtt.GetCodepointSDF(&info, scale, c.int(cp), c.int(padding), 128, 128.0 / f32(padding), &b.w, &b.h, &b.xo, &b.yo)
			append(&baked, b)
		}
	}
	defer for b in baked {
		if b.bmp != nil do stbtt.FreeSDF(b.bmp, nil)
	}

	rects := make([]stbrp.Rect, len(baked), context.temp_allocator)
	for b, i in baked {
		rects[i] = {id = c.int(i), w = stbrp.Coord(b.w + 1), h = stbrp.Coord(b.h + 1)}
	}
	atlas_dim := max(int(s.atlas_size), 128)
	packed := false
	for atlas_dim <= 4096 {
		nodes := make([]stbrp.Node, atlas_dim, context.temp_allocator)
		ctx: stbrp.Context
		stbrp.init_target(&ctx, c.int(atlas_dim), c.int(atlas_dim), raw_data(nodes), c.int(len(nodes)))
		if stbrp.pack_rects(&ctx, raw_data(rects), c.int(len(rects))) != 0 {
			packed = true
			break
		}
		atlas_dim *= 2
	}
	if !packed do return nil, false

	atlas := make([]u8, atlas_dim * atlas_dim, context.temp_allocator)
	glyphs := make([]Font_Glyph, len(baked), context.temp_allocator)
	for b, i in baked {
		r := rects[i]
		for y in 0 ..< int(b.h) {
			for x in 0 ..< int(b.w) {
				atlas[(int(r.y) + y) * atlas_dim + int(r.x) + x] = b.bmp[y * int(b.w) + x]
			}
		}
		glyphs[i] = Font_Glyph{
			codepoint = u32(b.cp),
			x0 = u16(r.x), y0 = u16(r.y), x1 = u16(int(r.x) + int(b.w)), y1 = u16(int(r.y) + int(b.h)),
			xoff = f32(b.xo), yoff = f32(b.yo),
			advance = b.advance,
		}
	}

	kerns := make([dynamic]Font_Kern, context.temp_allocator)
	for a in baked {
		for b in baked {
			k := stbtt.GetCodepointKernAdvance(&info, a.cp, b.cp)
			if k != 0 do append(&kerns, Font_Kern{u32(a.cp), u32(b.cp), f32(k) * scale})
		}
	}

	header := Font_Header{
		version     = FONT_VERSION,
		sampling    = sampling,
		padding     = f32(padding),
		ascent      = f32(asc) * scale,
		descent     = f32(-desc) * scale,
		line_gap    = f32(gap) * scale,
		atlas_w     = u32(atlas_dim),
		atlas_h     = u32(atlas_dim),
		glyph_count = u32(len(glyphs)),
		kern_count  = u32(len(kerns)),
	}
	copy(header.magic[:], FONT_MAGIC)
	out := make([dynamic]u8, 0, size_of(Font_Header) + len(glyphs) * size_of(Font_Glyph) + len(kerns) * size_of(Font_Kern) + len(atlas), allocator)
	append(&out, ..mem.ptr_to_bytes(&header))
	append(&out, ..slice.to_bytes(glyphs))
	append(&out, ..slice.to_bytes(kerns[:]))
	append(&out, ..atlas)
	return out[:], true
}

// A loaded font: the artifact bytes (owned) with the tables viewed into them.
Font :: struct {
	data:    []u8,
	header:  Font_Header,
	glyphs:  map[rune]Font_Glyph,
	kerns:   map[u64]f32,
	atlas:   []u8, // view into data
	texture: engine.Asset_GUID, // registered in engine.texture_cache; empty when headless
}

@(private = "file")
_kern_key :: proc(a, b: rune) -> u64 {
	return u64(u32(a)) << 32 | u64(u32(b))
}

// Views the tables of an artifact. `data` must outlive the result (the font
// keeps it). ok=false on a bad header.
font_parse :: proc(data: []u8, allocator := context.allocator) -> (f: Font, ok: bool) {
	if len(data) < size_of(Font_Header) do return {}, false
	f.data = data
	f.header = (cast(^Font_Header)raw_data(data))^
	if string(f.header.magic[:]) != FONT_MAGIC || f.header.version != FONT_VERSION do return {}, false
	off := size_of(Font_Header)
	gn := int(f.header.glyph_count)
	kn := int(f.header.kern_count)
	an := int(f.header.atlas_w) * int(f.header.atlas_h)
	if off + gn * size_of(Font_Glyph) + kn * size_of(Font_Kern) + an > len(data) do return {}, false
	glyphs := slice.reinterpret([]Font_Glyph, data[off:off + gn * size_of(Font_Glyph)])
	off += gn * size_of(Font_Glyph)
	kerns := slice.reinterpret([]Font_Kern, data[off:off + kn * size_of(Font_Kern)])
	off += kn * size_of(Font_Kern)
	f.atlas = data[off:off + an]
	f.glyphs = make(map[rune]Font_Glyph, gn, allocator)
	for g in glyphs do f.glyphs[rune(g.codepoint)] = g
	f.kerns = make(map[u64]f32, kn, allocator)
	for k in kerns do f.kerns[_kern_key(rune(k.a), rune(k.b))] = k.adv
	return f, true
}

font_destroy :: proc(f: ^Font) {
	delete(f.glyphs)
	delete(f.kerns)
	delete(f.data)
	f^ = {}
}

// The font that ships with the package (assets/Roboto-Medium.ttf, Apache-2.0).
DEFAULT_FONT_GUID :: "22073e17-4d3a-44ab-a230-03bea296e8b7"

default_font_guid :: proc() -> engine.Asset_GUID {
	if g, err := uuid.read(DEFAULT_FONT_GUID); err == nil do return engine.Asset_GUID(g)
	return {}
}

// The SDF material that ships with the package (assets/materials/TextSDF.mat).
DEFAULT_MATERIAL_GUID :: "57209af0-8443-465e-ab7b-cd1deec09ec6"

default_material_guid :: proc() -> engine.Asset_GUID {
	if g, err := uuid.read(DEFAULT_MATERIAL_GUID); err == nil do return engine.Asset_GUID(g)
	return {}
}

// --- Runtime cache ---------------------------------------------------------------------------

_fonts: map[engine.Asset_GUID]Font

// The atlas texture's guid: the font's guid with a marker folded in, so it
// never collides with an asset and stays the same across sessions.
@(private = "file")
_atlas_guid :: proc(font: engine.Asset_GUID) -> engine.Asset_GUID {
	g := font
	g[14] ~= 0x5D
	g[15] ~= 0xF2
	return g
}

// Registers the atlas as a texture (white with the field in alpha) when there
// is a GPU; headless callers get metrics and layout without one.
@(private = "file")
_font_upload :: proc(guid: engine.Asset_GUID, f: ^Font) {
	if gfx.device() == nil do return
	w, h := i32(f.header.atlas_w), i32(f.header.atlas_h)
	rgba := make([]u8, int(w * h * 4), context.temp_allocator)
	for a, i in f.atlas {
		rgba[i * 4 + 0] = 255
		rgba[i * 4 + 1] = 255
		rgba[i * 4 + 2] = 255
		rgba[i * 4 + 3] = a
	}
	tex_guid := _atlas_guid(guid)
	if old, had := engine.texture_cache[tex_guid]; had {
		gfx.texture_destroy(old.gfx)
		delete_key(&engine.texture_cache, tex_guid)
	}
	engine.texture_cache[tex_guid] = engine.Texture2D{guid = tex_guid, width = w, height = h, pixels_per_unit = engine.PIXELS_PER_UNIT, gfx = gfx.texture_create(rgba, w, h)}
	f.texture = tex_guid
}

// Puts a parsed font in the cache under `guid` (tests, tooling). Takes
// ownership of the font.
font_cache_insert :: proc(guid: engine.Asset_GUID, f: Font) {
	context.allocator = runtime.default_allocator()
	if _fonts == nil do _fonts = make(map[engine.Asset_GUID]Font)
	if old, had := &_fonts[guid]; had do font_destroy(old)
	_fonts[guid] = f
	if f.header.glyph_count > 0 do _font_upload(guid, &_fonts[guid])
}

// The font for a .ttf/.otf asset: cache hit, or its artifact read and parsed
// (in the editor a missing artifact triggers the import first).
font_load :: proc(guid: engine.Asset_GUID) -> (^Font, bool) {
	if f, ok := &_fonts[guid]; ok do return f, f.header.glyph_count > 0
	path, path_ok := engine.asset_pipeline_artifact_path(guid)
	if !path_ok {
		src, src_ok := engine.asset_db_get_path(uuid.Identifier(guid))
		if !src_ok do return nil, false
		_ = engine.asset_pipeline_request_import(src, force = false)
		path, path_ok = engine.asset_pipeline_artifact_path(guid)
		if !path_ok do return nil, false
	}
	data, rerr := os.read_entire_file(path, runtime.default_allocator())
	if rerr != nil do return nil, false
	f, ok := font_parse(data, runtime.default_allocator())
	if !ok {
		delete(data, runtime.default_allocator())
		// An unreadable artifact: force one reimport in the editor and read
		// the fresh one. Still unreadable: cache the failure as an empty font
		// so a broken artifact is not re-read every frame; the next reimport
		// evicts it through the hook.
		if src, src_ok := engine.asset_db_get_path(uuid.Identifier(guid)); src_ok && engine.asset_pipeline_request_import(src, force = true) {
			if path, path_ok = engine.asset_pipeline_artifact_path(guid); path_ok {
				if data, rerr = os.read_entire_file(path, runtime.default_allocator()); rerr == nil {
					f, ok = font_parse(data, runtime.default_allocator())
					if !ok do delete(data, runtime.default_allocator())
				}
			}
		}
		if !ok {
			font_cache_insert(guid, Font{})
			return nil, false
		}
	}
	font_cache_insert(guid, f)
	return &_fonts[guid], true
}

// Reimport hook: a rebaked artifact evicts its font so the next draw reloads.
font_reimported :: proc(guid: engine.Asset_GUID) {
	if f, ok := &_fonts[guid]; ok {
		font_destroy(f)
		delete_key(&_fonts, guid)
	}
}

// --- Backend for packages/text's layout -------------------------------------------------------
//
// Metrics are stored at the sampling size; a request at `size_px` scales them
// by size_px / sampling. The atlas is one texture per font, every size.

@(private = "file")
_sdf_scale :: proc(f: ^Font, size_px: f32) -> f32 {
	return size_px / max(f.header.sampling, 1)
}

@(private = "file")
_sdf_metrics :: proc(font: engine.Asset_GUID, size_px: f32) -> (Line_Metrics, bool) {
	f, ok := font_load(font)
	if !ok do return {}, false
	s := _sdf_scale(f, size_px)
	return {f.header.ascent * s, f.header.descent * s, f.header.line_gap * s}, true
}

@(private = "file")
_sdf_glyph :: proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (Glyph, bool) {
	f, ok := font_load(font)
	if !ok do return {}, false
	g, found := f.glyphs[r]
	if !found do g, found = f.glyphs['?']
	if !found do return {}, false
	s := _sdf_scale(f, size_px)
	w := f32(g.x1 - g.x0)
	h := f32(g.y1 - g.y0)
	aw, ah := f32(f.header.atlas_w), f32(f.header.atlas_h)
	u0, u1 := f32(g.x0) / aw, f32(g.x1) / aw
	v0, v1 := f32(g.y0) / ah, f32(g.y1) / ah
	return Glyph{
		advance = g.advance * s,
		size    = {w * s, h * s},
		offset  = {g.xoff * s, -(g.yoff + h) * s}, // stb: y down from the baseline; the quad's bottom is yoff + h
		uvs     = { {u0, v1}, {u1, v1}, {u1, v0}, {u0, v0} },
		texture = f.texture,
	}, true
}

@(private = "file")
_sdf_kern :: proc(font: engine.Asset_GUID, size_px: f32, a, b: rune) -> f32 {
	f, ok := font_load(font)
	if !ok do return 0
	return f.kerns[_kern_key(a, b)] * _sdf_scale(f, size_px)
}

sdf_backend :: proc() -> Backend {
	return Backend{name = "sdf", metrics = _sdf_metrics, glyph = _sdf_glyph, kern = _sdf_kern}
}

// Where the artifact for a font goes: the pipeline names it; this is the
// import entry the editor package registers.
font_import :: proc(source_path, artifact_path: string, settings: rawptr) -> bool {
	s := FontSettings{}
	if settings != nil {
		s = (cast(^FontSettings)settings)^
	} else {
		s = make_pFontSettings().(FontSettings)
	}
	ttf, rerr := os.read_entire_file(source_path, context.temp_allocator)
	if rerr != nil do return false
	artifact, ok := font_bake(ttf, s, context.temp_allocator)
	if !ok {
		fmt.printf("[Pipeline] Failed to bake font: %s\n", source_path)
		return false
	}
	if os.write_entire_file(artifact_path, artifact) != nil do return false
	fmt.printf("[Pipeline] Imported font: %s -> %s\n", source_path, artifact_path)
	return true
}

