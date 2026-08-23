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


