package engine

import "core:os"
import "core:fmt"

@(typ_guid={guid="ec017cc2-7267-45b4-ae80-d6861094d27a", makeProcName=make_pAudioSettings})
AudioSettings :: struct {
    volume: f32,
}

default_audio_settings :: proc() -> AudioSettings {
    return AudioSettings{
        volume = 1.0,
    }
}

make_pAudioSettings :: proc() -> any{
    p := new(AudioSettings)
    p.volume = 1.0
    return p^
}

_import_audio :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    data, read_err := os.read_entire_file(source_path, context.temp_allocator)
    if read_err != nil {
        fmt.printf("[Pipeline] Failed to read audio: %s\n", source_path)
        return false
    }

    _ensure_artifact_dir(artifact_path)

    if write_err := os.write_entire_file(artifact_path, data); write_err != nil {
        fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
        return false
    }

    fmt.printf("[Pipeline] Imported audio: %s -> %s\n", source_path, artifact_path)
    return true
}
