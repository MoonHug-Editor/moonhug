package engine

import "core:os"
import "core:fmt"

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
// rect plus a pivot. Renderers reference a slice by NAME — stable across
// reslicing, Unity's fileID-from-name model.
Sprite_Rect :: struct {
    name:  string,
    rect:  [4]f32, // x, y, w, h in pixels; origin top-left, y down (stb rows)
    pivot: [2]f32, // normalized within the rect, {0, 0} = bottom-left, {0.5, 0.5} = center
}

Sprite_Import_Mode :: enum u8 {
    Single,   // the whole texture is one sprite
    Multiple, // `sprites` lists the slices
}

@(typ_guid={guid="21d45bcf-2bd8-44db-b780-953c2f8b610f", makeProcName=make_pTextureSettings})
TextureSettings :: struct {
    filter:   TextureFilterMode,
    wrap:     TextureWrapMode,
    srgb:     bool,
    max_size: u16,
    // Unity's Pixels Per Unit: a sprite's world size = pixel size / this.
    // 100 (the default) makes 100 px = 1 world unit = 1 m, the physics
    // convention (docs/FixedTick.md). Metas predating the field keep the
    // factory default — the pipeline overlays metas onto defaulted instances.
    pixels_per_unit: f32,
    // Unity's TextureImporter.spriteImportMode: slicing is importer data, so
    // it bakes into the catalog with the rest of the settings and reaches
    // game builds with no extra pipeline.
    sprite_mode: Sprite_Import_Mode,
    sprites:     [dynamic]Sprite_Rect,
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

make_pTextureSettings :: proc() -> any {
    p := new(TextureSettings)
    p^ = default_texture_settings()
    return p^
}


