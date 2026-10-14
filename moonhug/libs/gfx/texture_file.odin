package gfx

// Decodes an image file (PNG, JPG, anything stb reads) into a GPU texture.
// The engine's texture cache and the editor's own images (the About logo)
// both load through here.

import "core:os"
import stbi "vendor:stb/image"

// nil when there is no device or the file does not decode.
texture_load_file :: proc(path: string) -> (^Texture, bool) {
	if device() == nil do return nil, false
	tex := texture_decode_file(path)
	return tex, tex != nil
}

// stb decodes top-down RGBA8, matching SDL_GPU's top-left uv origin.
texture_decode_file :: proc(path: string) -> ^Texture {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil

	w, h, channels: i32
	// A Radiance .hdr image: linear float, kept as half floats.
	if stbi.is_hdr_from_memory(raw_data(data), i32(len(data))) != 0 {
		floats := stbi.loadf_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
		if floats == nil do return nil
		defer stbi.image_free(floats)
		halves := make([][4]f16, int(w * h), context.temp_allocator)
		for i in 0 ..< int(w * h) {
			halves[i] = {f16(floats[i * 4]), f16(floats[i * 4 + 1]), f16(floats[i * 4 + 2]), f16(floats[i * 4 + 3])}
		}
		return texture_create_hdr(halves, w, h)
	}
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return nil
	defer stbi.image_free(pixels)

	return texture_create(pixels[:w * h * 4], w, h)
}
