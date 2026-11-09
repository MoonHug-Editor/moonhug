package engine_tests

// Texture import with max_size: an image larger than it is scaled down so
// its larger side is max_size, behind a header naming the source's size. An
// image that fits keeps its bytes. Headless: the importer decodes and encodes
// with stb, no GPU.

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import stbi "vendor:stb/image"

@(test)
texture_scaled_size_keeps_the_aspect :: proc(t: ^testing.T) {
	size, scaled := engine.texture_scaled_size(256, 256, 0)
	testing.expect(t, !scaled && size == {256, 256}, "0 keeps the size")
	size, scaled = engine.texture_scaled_size(256, 128, 256)
	testing.expect(t, !scaled && size == {256, 128}, "an image that fits keeps its size")
	size, scaled = engine.texture_scaled_size(1024, 512, 256)
	testing.expectf(t, scaled && size == {256, 128}, "the larger side becomes max_size, %v", size)
	size, scaled = engine.texture_scaled_size(300, 1000, 100)
	testing.expectf(t, scaled && size == {30, 100}, "a tall image, %v", size)
	size, scaled = engine.texture_scaled_size(4096, 2, 64)
	testing.expectf(t, scaled && size == {64, 1}, "never below 1 pixel, %v", size)
}

@(test)
texture_max_size_scales_the_artifact_down :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_texture_max_size_tmp"
	png :: src_dir + "/probe.png"
	hdr :: src_dir + "/probe.hdr"
	os.make_directory(src_dir)
	defer {
		for p in ([]string{png, png + ".meta", hdr, hdr + ".meta"}) do os.remove(p)
		os.remove(src_dir)
		_remove_tree(engine.library_dir())
	}
	data, rerr := os.read_entire_file("moonhug/tests/fixtures/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)
	testing.expect(t, os.write_entire_file(hdr, _small_hdr(8, 4)) == nil)

	asset_pipeline.asset_pipeline_init()

	// No max_size: the artifact is the source's bytes.
	png_guid := _imported_guid(t, png)
	art := _artifact_bytes(t, png_guid)
	_, _, scaled := engine.texture_artifact_split(art)
	testing.expect(t, !scaled && len(art) == len(data), "an unscaled artifact is the source's bytes")

	// max_size 64: a 64 x 64 image behind a header naming 256 x 256.
	_set_max_size(t, png, 64)
	art = _artifact_bytes(t, png_guid)
	image, source_size, is_scaled := engine.texture_artifact_split(art)
	testing.expect(t, is_scaled, "the artifact has the header")
	testing.expect_value(t, source_size, [2]i32{256, 256})
	w, h, comp: i32
	testing.expect(t, stbi.info_from_memory(raw_data(image), i32(len(image)), &w, &h, &comp) != 0, "the image decodes")
	testing.expect_value(t, [2]i32{w, h}, [2]i32{64, 64})

	// A max_size the image fits in: the source's bytes again.
	_set_max_size(t, png, 512)
	art = _artifact_bytes(t, png_guid)
	_, _, scaled = engine.texture_artifact_split(art)
	testing.expect(t, !scaled && len(art) == len(data), "an image that fits keeps its bytes")

	// An HDR image stays HDR: an 8 x 4 image at max_size 4 is 4 x 2.
	hdr_guid := _imported_guid(t, hdr)
	_set_max_size(t, hdr, 4)
	art = _artifact_bytes(t, hdr_guid)
	image, source_size, is_scaled = engine.texture_artifact_split(art)
	testing.expect(t, is_scaled)
	testing.expect_value(t, source_size, [2]i32{8, 4})
	testing.expect(t, stbi.is_hdr_from_memory(raw_data(image), i32(len(image))) != 0, "still a Radiance image")
	testing.expect(t, stbi.info_from_memory(raw_data(image), i32(len(image)), &w, &h, &comp) != 0)
	testing.expect_value(t, [2]i32{w, h}, [2]i32{4, 2})
}

// Imports `path` and returns the guid its meta minted.
@(private = "file")
_imported_guid :: proc(t: ^testing.T, path: string) -> engine.Asset_GUID {
	asset_pipeline.asset_pipeline_ensure_import_meta(path)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(path), "the first import runs")
	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, _ := os.read_entire_file(strings.concatenate({path, ".meta"}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw, err := uuid.read(meta.guid)
	testing.expect(t, err == nil)
	return engine.Asset_GUID(raw)
}

@(private = "file")
_set_max_size :: proc(t: ^testing.T, path: string, max_size: u16) {
	s, ok := engine.asset_pipeline_get_settings(path)
	testing.expect(t, ok)
	if !ok do return
	defer free(s.data) // the caller owns the settings instance
	ts := s.(engine.TextureSettings)
	ts.max_size = max_size
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(path, ts))
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(path), "the settings change imports")
}

@(private = "file")
_artifact_bytes :: proc(t: ^testing.T, guid: engine.Asset_GUID) -> []u8 {
	p, ok := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok)
	if !ok do return nil
	data, err := os.read_entire_file(p, context.temp_allocator)
	testing.expect(t, err == nil)
	return data
}

// A w x h Radiance image of a grey ramp, encoded by stb.
@(private = "file")
_small_hdr :: proc(w, h: i32) -> []u8 {
	pixels := make([]f32, int(w * h * 3), context.temp_allocator)
	for &v, i in pixels do v = f32(i % int(w * 3)) / f32(w * 3) * 4
	out := make([dynamic]u8, context.temp_allocator)
	append_bytes :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = runtime.default_context()
		buf := cast(^[dynamic]u8)ctx
		append(buf, ..([^]u8)(data)[:size])
	}
	stbi.write_hdr_to_func(append_bytes, &out, w, h, 3, raw_data(pixels))
	return out[:]
}

@(test)
texture_type_sets_the_wrap_it_expects :: proc(t: ^testing.T) {
	// A new texture is Default and repeats, as a meta without the type reads.
	ts := engine.default_texture_settings()
	testing.expect_value(t, ts.texture_type, engine.Texture_Type.Default)
	testing.expect_value(t, ts.wrap, engine.TextureWrapMode.Repeat)

	// A Sprite clamps. The other settings stay as they are.
	ts.texture_type = .Sprite
	ts.filter = .Nearest
	engine.texture_type_defaults(&ts)
	testing.expect_value(t, ts.wrap, engine.TextureWrapMode.Clamp)
	testing.expect_value(t, ts.filter, engine.TextureFilterMode.Nearest)

	ts.texture_type = .Default
	engine.texture_type_defaults(&ts)
	testing.expect_value(t, ts.wrap, engine.TextureWrapMode.Repeat)
}
