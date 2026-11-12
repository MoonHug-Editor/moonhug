package gfx

// Decodes an image file (PNG, JPG, anything stb reads) into a GPU texture.
// The engine's texture cache and the editor's own images (the About logo)
// both load through here.

import "base:runtime"
import "core:os"
import stbi "vendor:stb/image"

// nil when there is no device or the file does not decode.
texture_load_file :: proc(path: string) -> (^Texture, bool) {
	if device() == nil do return nil, false
	tex := texture_decode_file(path)
	return tex, tex != nil
}

// stb decodes top-down RGBA8, matching SDL_GPU's top-left uv origin.
// `mipmaps` gives an 8-bit image its mip chain (texture_create). An HDR image
// keeps one level: its reader (the environment's capture) samples level 0.
texture_decode_file :: proc(path: string, mipmaps := false) -> ^Texture {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil
	return texture_decode_bytes(data, mipmaps)
}

// texture_decode_file on an image already in memory. nil when it does not
// decode.
texture_decode_bytes :: proc(data: []u8, mipmaps := false) -> ^Texture {
	img, ok := image_decode(data)
	if !ok do return nil
	defer image_free(&img)
	return texture_from_image(img, mipmaps)
}

// The pixels of a decoded image file, before they are a GPU texture. An HDR
// image has `halves`, any other has `pixels`.
Decoded_Image :: struct {
	pixels: []u8, // RGBA8, top-down, owned by stb
	halves: [][4]f16, // linear half floats, on the default allocator
	width:  i32,
	height: i32,
}

// Decodes an image file's bytes. It uses no GPU and no gfx state, so it runs
// on any thread. Pair with image_free.
image_decode :: proc(data: []u8) -> (img: Decoded_Image, ok: bool) {
	if len(data) == 0 do return
	channels: i32
	// A Radiance .hdr image: linear float, kept as half floats.
	if stbi.is_hdr_from_memory(raw_data(data), i32(len(data))) != 0 {
		floats := stbi.loadf_from_memory(raw_data(data), i32(len(data)), &img.width, &img.height, &channels, 4)
		if floats == nil do return {}, false
		defer stbi.image_free(floats)
		count := int(img.width * img.height)
		img.halves = make([][4]f16, count, runtime.default_allocator())
		for i in 0 ..< count {
			img.halves[i] = {f16(floats[i * 4]), f16(floats[i * 4 + 1]), f16(floats[i * 4 + 2]), f16(floats[i * 4 + 3])}
		}
		return img, true
	}
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &img.width, &img.height, &channels, 4)
	if pixels == nil do return {}, false
	img.pixels = pixels[:img.width * img.height * 4]
	return img, true
}

image_free :: proc(img: ^Decoded_Image) {
	if img.pixels != nil do stbi.image_free(raw_data(img.pixels))
	if img.halves != nil do delete(img.halves, runtime.default_allocator())
	img^ = {}
}

// The GPU texture of a decoded image. Main thread. `mipmaps` gives an 8-bit
// image its mip chain. nil when the upload fails.
texture_from_image :: proc(img: Decoded_Image, mipmaps := false) -> ^Texture {
	if img.halves != nil do return texture_create_hdr(img.halves, img.width, img.height)
	if img.pixels == nil do return nil
	return texture_create(img.pixels, img.width, img.height, mipmaps)
}
