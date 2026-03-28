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
}

default_texture_settings :: proc() -> TextureSettings {
    return TextureSettings{
        filter   = .Linear,
        wrap     = .Repeat,
        srgb     = true,
        max_size = 0,
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

