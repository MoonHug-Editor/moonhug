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

@(typ_guid={guid="21d45bcf-2bd8-44db-b780-953c2f8b610f"})
TextureSettings :: struct {
    filter:   TextureFilterMode,
    wrap:     TextureWrapMode,
    srgb:     bool,
    max_size: u16,
    // Unity's Pixels Per Unit: a sprite's world size = pixel size / this.
    // 100 (the default) makes 100 px = 1 world unit = 1 m, the physics
    // convention (docs/FixedTick.md). Metas predating the field read as 0
    // and normalize to 100 (_read_import_meta).
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

_import_texture :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    data, read_err := os.read_entire_file(source_path, context.temp_allocator)
    if read_err != nil {
        fmt.printf("[Pipeline] Failed to read texture: %s\n", source_path)
        return false
    }

    _ensure_artifact_dir(artifact_path)

    if write_err := os.write_entire_file(artifact_path, data); write_err != nil {
        fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
        return false
    }

    fmt.printf("[Pipeline] Imported texture: %s -> %s\n", source_path, artifact_path)
    return true
}

