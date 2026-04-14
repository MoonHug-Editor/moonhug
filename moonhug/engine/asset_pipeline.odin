package engine

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "../engine/json"
import "core:encoding/uuid"
import "core:time"

ARTIFACTS_DIR :: "library/artifacts"

ImportSettings :: union #no_nil{
    TextureSettings,
    AudioSettings,
}

ImportMeta :: struct {
    guid:     string,
    importer: string,
    settings: ImportSettings,
}

is_importable_extension :: proc(ext: string) -> bool {
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp":
        return true
    case ".mp3", ".wav", ".ogg":
        return true
    }
    return false
}

settings_for_extension :: proc(ext: string) -> ImportSettings {
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp":
        return default_texture_settings()
    case ".mp3", ".wav", ".ogg":
        return default_audio_settings()
    }
    return {}
}

asset_pipeline_init :: proc() {
    os.make_directory("library")
    os.make_directory(ARTIFACTS_DIR)
}

asset_pipeline_import_all :: proc() {
    _import_directory(asset_db.root_path)
    _cleanup_stale_artifacts()
    fmt.printf("[Pipeline] Import pass complete\n")
}

asset_pipeline_import_asset :: proc(source_path: string) -> bool {
    ext := filepath.ext(source_path)
    if !is_importable_extension(ext) do return false

    meta_path := strings.concatenate({source_path, ".meta"})
    defer delete(meta_path)

    import_meta := _read_import_meta(meta_path)
    if import_meta.guid == "" do return false
    defer delete(import_meta.guid)

    guid, parse_err := uuid.read(import_meta.guid)
    if parse_err != nil do return false

    artifact_path := _artifact_path(guid)
    defer delete(artifact_path)

    if !_needs_reimport(source_path, artifact_path) do return false

    return _run_import(source_path, artifact_path, import_meta.settings)
}

asset_pipeline_reimport :: proc(source_path: string) -> bool {
    ext := filepath.ext(source_path)
    if !is_importable_extension(ext) do return false

    meta_path := strings.concatenate({source_path, ".meta"})
    defer delete(meta_path)

    import_meta := _read_import_meta(meta_path)
    if import_meta.guid == "" do return false
    defer delete(import_meta.guid)

    guid, parse_err := uuid.read(import_meta.guid)
    if parse_err != nil do return false

    artifact_path := _artifact_path(guid)
    defer delete(artifact_path)

    return _run_import(source_path, artifact_path, import_meta.settings)
}

asset_pipeline_get_settings :: proc(source_path: string) -> (ImportSettings, bool) {
    meta_path := strings.concatenate({source_path, ".meta"})
    defer delete(meta_path)

    import_meta := _read_import_meta(meta_path)
    if import_meta.guid == "" do return {}, false
    delete(import_meta.guid)

    return import_meta.settings, true
}

asset_pipeline_save_settings :: proc(source_path: string, settings: ImportSettings) -> bool {
    meta_path := strings.concatenate({source_path, ".meta"})
    defer delete(meta_path)

    import_meta := _read_import_meta(meta_path)
    if import_meta.guid == "" do return false

    import_meta.settings = settings
    return _write_import_meta(meta_path, import_meta)
}

_import_directory :: proc(dir_path: string) {
    handle, err := os.open(dir_path)
    if err != nil do return
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil do return
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    for entry in entries {
        if strings.has_prefix(entry.name, ".") do continue

        full_path, _ := filepath.join({dir_path, entry.name}, context.temp_allocator)

        if entry.type == .Directory {
            _import_directory(full_path)
        } else {
            if strings.has_suffix(entry.name, ".meta") do continue
            ext := filepath.ext(entry.name)
            if is_importable_extension(ext) {
                asset_pipeline_import_asset(full_path)
            }
        }
    }
}

_needs_reimport :: proc(source_path: string, artifact_path: string) -> bool {
    source_info, s_err := os.stat(source_path, context.temp_allocator)
    if s_err != nil do return false
    defer os.file_info_delete(source_info, context.temp_allocator)

    artifact_info, a_err := os.stat(artifact_path, context.temp_allocator)
    if a_err != nil do return true
    defer os.file_info_delete(artifact_info, context.temp_allocator)

    return time.diff(artifact_info.modification_time, source_info.modification_time) > 0
}

_run_import :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    ext := filepath.ext(source_path)
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp":
        return _import_texture(source_path, artifact_path, settings)
    case ".mp3", ".wav", ".ogg":
        return _import_audio(source_path, artifact_path, settings)
    }
    return false
}

_ensure_artifact_dir :: proc(artifact_path: string) {
    dir := filepath.dir(artifact_path, context.temp_allocator)
    os.make_directory(dir)
}

_cleanup_stale_artifacts :: proc() {
    handle, err := os.open(ARTIFACTS_DIR)
    if err != nil do return
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil do return
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    removed := 0
    for entry in entries {
        if entry.type == .Directory do continue
        if !strings.has_suffix(entry.name, ".bin") do continue

        guid_str := strings.trim_suffix(entry.name, ".bin")
        guid, parse_err := uuid.read(guid_str)
        if parse_err != nil {
            full_path, _ := filepath.join({ARTIFACTS_DIR, entry.name}, context.temp_allocator)
            os.remove(full_path)
            removed += 1
            continue
        }

        if _, ok := asset_db.guid_to_path[guid]; !ok {
            full_path, _ := filepath.join({ARTIFACTS_DIR, entry.name}, context.temp_allocator)
            os.remove(full_path)
            removed += 1
        }
    }

    if removed > 0 {
        fmt.printf("[Pipeline] Removed %d stale artifact(s)\n", removed)
    }
}

_artifact_path :: proc(guid: uuid.Identifier) -> string {
    guid_str := uuid.to_string(guid)
    defer delete(guid_str)
    bin_name := strings.concatenate({guid_str, ".bin"})
    defer delete(bin_name)
    path, _ := filepath.join({ARTIFACTS_DIR, bin_name}, context.allocator)
    return path
}

_read_import_meta :: proc(meta_path: string) -> ImportMeta {
    data, read_err := os.read_entire_file(meta_path, context.temp_allocator)
    if read_err != nil do return {}

    result: ImportMeta
    unmarshal_err := json.unmarshal(data, &result, allocator=context.temp_allocator)
    if unmarshal_err != nil do return {}

    if result.guid == "" {
        return {}
    }

    return ImportMeta{
        guid     = strings.clone(result.guid),
        importer = result.importer,
        settings = result.settings,
    }
}

_write_import_meta :: proc(meta_path: string, meta: ImportMeta) -> bool {
    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }
    data, err := json.marshal(meta, opts)
    if err != nil do return false
    defer delete(data)

    return os.write_entire_file(meta_path, data) == nil
}

asset_pipeline_ensure_import_meta :: proc(asset_path: string) {
    ext := filepath.ext(asset_path)
    if !is_importable_extension(ext) do return

    meta_path := strings.concatenate({asset_path, ".meta"})
    defer delete(meta_path)

    existing := _read_import_meta(meta_path)
    if existing.guid != "" && existing.importer != "" {
        delete(existing.guid)
        return
    }

    guid_id: uuid.Identifier
    if existing.guid != "" {
        parsed, parse_err := uuid.read(existing.guid)
        if parse_err == nil {
            guid_id = parsed
        }
        delete(existing.guid)
    }

    if guid_id == {} {
        if g, ok := _read_meta(meta_path); ok {
            guid_id = g
        } else {
            guid_id = _generate_guid()
        }
    }

    guid_str := uuid.to_string(guid_id)
    defer delete(guid_str)

    importer_name: string
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp":
        importer_name = "texture"
    case ".mp3", ".wav", ".ogg":
        importer_name = "audio"
    }

    new_meta := ImportMeta{
        guid     = guid_str,
        importer = importer_name,
        settings = settings_for_extension(ext),
    }

    _write_import_meta(meta_path, new_meta)
}
