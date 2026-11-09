package importers

// Texture import: the source bytes copied into the artifact (decode happens
// at load), or, when the image is larger than the settings' max_size, the
// image scaled down and encoded again behind a header naming the source's
// size (engine.texture_artifact_header). Settings (engine.TextureSettings)
// ride the artifact key, so a settings change re-imports.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "moonhug:packages/engine"
import stbi "vendor:stb/image"

_import_texture :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		fmt.printf("[Pipeline] Failed to read texture: %s\n", source_path)
		return false
	}

	ts := settings != nil ? (cast(^engine.TextureSettings)settings)^ : engine.default_texture_settings()
	scaled_bytes: [dynamic]u8
	defer delete(scaled_bytes)
	scaled, scale_ok := _texture_scale_down(data, ts.max_size, ts.srgb, &scaled_bytes)
	if !scale_ok {
		fmt.printf("[Pipeline] Failed to scale texture down to %d: %s\n", ts.max_size, source_path)
		return false
	}
	out := scaled ? scaled_bytes[:] : data

	engine._ensure_artifact_dir(artifact_path)

	if write_err := os.write_entire_file(artifact_path, out); write_err != nil {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}

	fmt.printf("[Pipeline] Imported texture: %s -> %s\n", source_path, artifact_path)
	return true
}

// Writes the artifact of an image larger than `max_size` into `out`: the
// header, then the image scaled down (engine.texture_scaled_size) as a PNG,
// or as a Radiance file for an HDR image. `scaled` is false when the image
// fits and the source bytes are the artifact as they are. An sRGB image is
// filtered in linear light, so its scaled colours keep their brightness.
_texture_scale_down :: proc(data: []u8, max_size: u16, srgb: bool, out: ^[dynamic]u8) -> (scaled: bool, ok: bool) {
	if max_size == 0 do return false, true
	w, h, comp: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp) == 0 do return false, false
	size, needs := engine.texture_scaled_size(w, h, max_size)
	if !needs do return false, true

	header := engine.texture_artifact_header({w, h})
	append(out, ..header[:])
	if stbi.is_hdr_from_memory(raw_data(data), i32(len(data))) != 0 {
		src := stbi.loadf_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
		if src == nil do return false, false
		defer stbi.image_free(src)
		dst := make([]f32, int(size.x * size.y * 4))
		defer delete(dst)
		if stbi.resize_float(src, w, h, 0, raw_data(dst), size.x, size.y, 0, 4) == 0 do return false, false
		if stbi.write_hdr_to_func(_append_bytes, out, size.x, size.y, 4, raw_data(dst)) == 0 do return false, false
		return true, true
	}
	src := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
	if src == nil do return false, false
	defer stbi.image_free(src)
	dst := make([]u8, int(size.x * size.y * 4))
	defer delete(dst)
	resized: c.int
	if srgb {
		resized = stbi.resize_uint8_srgb(src, w, h, 0, raw_data(dst), size.x, size.y, 0, 4, 3, 0)
	} else {
		resized = stbi.resize_uint8(src, w, h, 0, raw_data(dst), size.x, size.y, 0, 4)
	}
	if resized == 0 do return false, false
	if stbi.write_png_to_func(_append_bytes, out, size.x, size.y, 4, raw_data(dst), size.x * 4) == 0 do return false, false
	return true, true
}

// stb's writer callback: appends the encoded bytes to the [dynamic]u8 in ctx.
@(private = "file")
_append_bytes :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	context = runtime.default_context()
	buf := cast(^[dynamic]u8)ctx
	append(buf, ..([^]u8)(data)[:size])
}
