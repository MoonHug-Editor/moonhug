package engine

import "core:encoding/endian"
import "core:math"


// What a texture is for. Choosing a type in the inspector sets the settings
// it expects (texture_type_defaults): a Sprite clamps at its edges, so its
// border never samples the opposite one under linear filtering.
Texture_Type :: enum u8 {
    Default,
    Sprite,
}

TextureFilterMode :: enum {
    Linear,
    Nearest,
}

TextureWrapMode :: enum {
    Repeat,
    Clamp,
    Mirror,
}

// One slice of a texture (Unity's Sprite sub-asset, importer-owned): a pixel
// rect plus a pivot. Renderers reference a slice as PPtr{texture guid,
// slice id} — Unity's guid+fileID. The id is the persistent identity, minted
// by the slicer and kept across renames and reslicing (the meta's slice list
// doubles as Unity's internalIDToNameTable). The name is a view detail.
Sprite_Rect :: struct {
    id:    Local_ID,
    name:  string,
    rect:  [4]f32, // x, y, w, h in pixels; origin top-left, y down (stb rows)
    pivot: [2]f32, // normalized within the rect, {0, 0} = bottom-left, {0.5, 0.5} = center
    border: [4]f32, // 9-slice borders in pixels: left, bottom, right, top (Unity's Sprite.border)
}

// Whether a texture gets its chain of mip levels (gfx.texture_create): the
// smaller copies a texture seen small samples from. Generate is the zero value,
// so a meta predating the field generates them. None suits a sliced sprite
// atlas, whose slices would bleed into each other in the smaller levels.
Texture_Mipmaps :: enum u8 {
    Generate,
    None,
}

Sprite_Import_Mode :: enum u8 {
    Single,   // the whole texture is one sprite
    Multiple, // `sprites` lists the slices
}

@(typ_guid={guid="21d45bcf-2bd8-44db-b780-953c2f8b610f"})
TextureSettings :: struct {
    texture_type: Texture_Type,
    filter:   TextureFilterMode,
    wrap:     TextureWrapMode,
    srgb:     bool,
    // The import scales a larger image down so its larger side is this many
    // pixels, keeping its aspect (texture_scaled_size). 0 keeps its size.
    max_size: u16,
    mipmaps:  Texture_Mipmaps,
    // Unity's Pixels Per Unit: a sprite's world size = pixel size / this.
    // 100 (the default) makes 100 px = 1 world unit = 1 m, the physics
    // convention (plugins/engine/docs/FixedTick.md). 0 means the default: a meta predating
    // the field reads 0, and type_on_validate_TextureSettings makes it 100.
    pixels_per_unit: f32,
    // Unity's TextureImporter.spriteImportMode: slicing is importer data, so
    // it bakes into the catalog with the rest of the settings and reaches
    // game builds with no extra pipeline.
    sprite_mode: Sprite_Import_Mode,
    sprites:     [dynamic]Sprite_Rect,
    // Single mode's 9-slice borders in pixels: left, bottom, right, top
    // (Unity's spriteBorder). Multiple mode keeps them per slice.
    sprite_border: [4]f32,
}

default_texture_settings :: proc() -> TextureSettings {
    return TextureSettings{
        filter   = .Linear,
        wrap     = .Repeat,
        srgb     = true,
        max_size = 0,
        pixels_per_unit = PIXELS_PER_UNIT,
    }
}

// A zero PPU is no value (a meta predating the field): the default.
type_on_validate_TextureSettings :: proc(s: ^TextureSettings) {
    if s.pixels_per_unit <= 0 do s.pixels_per_unit = PIXELS_PER_UNIT
}

type_cleanup_TextureSettings :: proc(s: ^TextureSettings) {
    for &r in s.sprites do delete(r.name)
    delete(s.sprites)
    s^ = {}
}

type_reset_TextureSettings :: proc(p: ^TextureSettings) {
    type_cleanup_TextureSettings(p)
    p^ = default_texture_settings()
}

// The settings a texture type expects, set when the type is chosen: a Sprite
// clamps, a Default texture repeats. Every other setting stays as it is.
texture_type_defaults :: proc(s: ^TextureSettings) {
    switch s.texture_type {
    case .Default: s.wrap = .Repeat
    case .Sprite:  s.wrap = .Clamp
    }
}

// --- The texture artifact ----------------------------------------------------

// A texture artifact is an image file's bytes. One the import scaled down
// (max_size) starts with a header naming the source's size: "MHTS", then the
// source width and height as little-endian u32. Sprite rects, pixels per unit
// and native sizes stay in source pixels, so the loader reports the source size
// and a smaller texture keeps its world size.
TEXTURE_ARTIFACT_MAGIC       :: "MHTS"
TEXTURE_ARTIFACT_HEADER_SIZE :: 12

texture_artifact_header :: proc(source_size: [2]i32) -> (h: [TEXTURE_ARTIFACT_HEADER_SIZE]u8) {
    copy(h[:4], TEXTURE_ARTIFACT_MAGIC)
    endian.unchecked_put_u32le(h[4:], u32(source_size.x))
    endian.unchecked_put_u32le(h[8:], u32(source_size.y))
    return
}

// The image bytes of a texture artifact, and the source size when the import
// scaled it down. A plain artifact is all image: `scaled` is false.
texture_artifact_split :: proc(data: []u8) -> (image: []u8, source_size: [2]i32, scaled: bool) {
    if len(data) < TEXTURE_ARTIFACT_HEADER_SIZE || string(data[:4]) != TEXTURE_ARTIFACT_MAGIC do return data, {}, false
    w := endian.unchecked_get_u32le(data[4:])
    h := endian.unchecked_get_u32le(data[8:])
    return data[TEXTURE_ARTIFACT_HEADER_SIZE:], {i32(w), i32(h)}, true
}

// The size the import scales a w x h image to: its larger side becomes
// `max_size` and the other keeps the aspect, at least 1 pixel. `scaled` is
// false when max_size is 0 or the image already fits.
texture_scaled_size :: proc(w, h: i32, max_size: u16) -> (size: [2]i32, scaled: bool) {
    longest := max(w, h)
    if max_size == 0 || longest <= i32(max_size) do return {w, h}, false
    k := f64(max_size) / f64(longest)
    return {max(1, i32(math.round(f64(w) * k))), max(1, i32(math.round(f64(h) * k)))}, true
}
