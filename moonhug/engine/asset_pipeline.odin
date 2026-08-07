package engine

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:encoding/json"
import "core:encoding/uuid"
import xxh "core:hash/xxhash"
import "base:runtime"

// Unity's Library model: everything under Library/ is derived data — safe to
// delete, rebuilt from assets + metas on the next run, never a source of
// truth. Import artifacts are CONTENT-ADDRESSED: the artifact key hashes every
// input that shapes the output (source bytes, import settings, importer
// version, artifact format version), so invalidation is automatic — changing
// any input is a different key, and toggling a setting back is a cache HIT on
// the old artifact, not a re-import. ArtifactDB.json maps guid -> current
// artifact key plus the file stamp and settings hash that make the per-scan
// freshness check cheap (no rehash of unchanged files).
LIBRARY_DIR      :: "Library"
ARTIFACTS_DIR    :: "Library/Artifacts" // Artifacts/<first 2 hex>/<32-hex key>.bin
ARTIFACT_DB_PATH :: "Library/ArtifactDB.json"

// Bump to invalidate EVERY artifact (artifact container format changes).
_ARTIFACT_FORMAT_VERSION :: 1

// Bump an importer's version when its OUTPUT changes — its artifacts re-import
// on the next run, nothing else does, and no one hand-deletes the Library.
_importer_version :: proc(importer: string) -> int {
	switch importer {
	case "texture": return 1
	case "audio":   return 1
	case "mesh":    return 1
	case "shader":  return 1
	}
	return 0
}

_importer_for_extension :: proc(ext: string) -> string {
	switch ext {
	case ".png", ".jpg", ".jpeg", ".bmp":
		return "texture"
	case ".mp3", ".wav", ".ogg":
		return "audio"
	case ".glb", ".gltf":
		return "mesh"
	case ".glsl":
		return "shader"
	}
	return ""
}

ImportSettings :: union #no_nil{
    TextureSettings,
    AudioSettings,
    MeshSettings,
    ShaderSettings,
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
    case ".glb", ".gltf":
        return true
    case ".glsl":
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
    case ".glb", ".gltf":
        return default_mesh_settings()
    case ".glsl":
        return default_shader_settings()
    }
    return {}
}

asset_pipeline_init :: proc() {
    os.make_directory(LIBRARY_DIR)
    os.make_directory(ARTIFACTS_DIR)
    _artifact_index_ensure()
}

asset_pipeline_import_all :: proc() {
    _artifact_index_batch = true // one index write for the whole pass
    _import_directory(asset_db.root_path)
    for root in asset_db_package_roots() {
        _import_directory(root.assets_path)
    }
    _artifact_index_batch = false
    _artifact_index_prune()
    _cleanup_stale_artifacts()
    _artifact_index_save()
    fmt.printf("[Pipeline] Import pass complete\n")
}

// Imports when needed: a source whose stamp AND settings match its index entry
// (with the artifact file present) is fresh and costs one stat + one meta
// read. Anything else computes the content key — a key whose artifact already
// exists (a setting toggled back) just re-points the index, no importer runs.
asset_pipeline_import_asset :: proc(source_path: string) -> bool {
    return _import_asset(source_path, force = false)
}

// Forced: always re-runs the importer into the current key's artifact.
asset_pipeline_reimport :: proc(source_path: string) -> bool {
    return _import_asset(source_path, force = true)
}

@(private = "file")
_import_asset :: proc(source_path: string, force: bool) -> bool {
    ext := filepath.ext(source_path)
    if !is_importable_extension(ext) do return false

    meta_path := strings.concatenate({source_path, ".meta"}, context.temp_allocator)
    import_meta := _read_import_meta(meta_path)
    if import_meta.guid == "" do return false
    defer delete(import_meta.guid)

    guid, parse_err := uuid.read(import_meta.guid)
    if parse_err != nil do return false

    _artifact_index_ensure()

    info, stat_err := os.stat(source_path, context.temp_allocator)
    if stat_err != nil do return false
    mtime := info.modification_time._nsec
    size := info.size

    settings_hex := _settings_hash_hex(import_meta.settings)
    if !force {
        if e, has := _artifact_index[guid]; has &&
           e.mtime == mtime && e.size == size && e.settings == settings_hex {
            if os.exists(_artifact_key_path(e.artifact, context.temp_allocator)) {
                return false
            }
        }
    }

    data, read_err := os.read_entire_file(source_path, context.temp_allocator)
    if read_err != nil do return false
    key := _artifact_key(data, import_meta.settings, _importer_for_extension(ext))
    artifact_path := _artifact_key_path(key, context.temp_allocator)

    if force || !os.exists(artifact_path) {
        _ensure_artifact_dir(artifact_path)
        if !_run_import(source_path, artifact_path, import_meta.settings) do return false
    }

    _artifact_index_set(guid, key, mtime, size, settings_hex)
    _artifact_index_save()
    return true
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
    defer delete(import_meta.guid)

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

// --- Artifact index (Library/ArtifactDB.json) --------------------------------

_Artifact_Entry :: struct {
    artifact: string, // 32-hex content key (owned)
    mtime:    i64,    // source stamp at import
    size:     i64,
    settings: string, // 16-hex settings hash (owned)
}

@(private = "file") _artifact_index: map[uuid.Identifier]_Artifact_Entry
@(private = "file") _artifact_index_loaded: bool
@(private = "file") _artifact_index_dirty: bool
@(private = "file") _artifact_index_batch: bool

// Lazy so every consumer works with no init wiring — the game binary loads
// artifacts through the same index the editor wrote.
@(private = "file")
_artifact_index_ensure :: proc() {
    if _artifact_index_loaded do return
    _artifact_index_loaded = true
    context.allocator = runtime.default_allocator()
    _artifact_index = make(map[uuid.Identifier]_Artifact_Entry)

    data, read_err := os.read_entire_file(ARTIFACT_DB_PATH, context.temp_allocator)
    if read_err != nil do return
    raw: map[string]_Artifact_Entry
    if json.unmarshal(data, &raw, allocator = context.temp_allocator) != nil do return
    for guid_str, e in raw {
        guid, perr := uuid.read(guid_str)
        if perr != nil do continue
        _artifact_index[guid] = _Artifact_Entry{
            artifact = strings.clone(e.artifact),
            mtime    = e.mtime,
            size     = e.size,
            settings = strings.clone(e.settings),
        }
    }
}

@(private = "file")
_artifact_index_set :: proc(guid: uuid.Identifier, key: string, mtime, size: i64, settings_hex: string) {
    context.allocator = runtime.default_allocator()
    if old, has := _artifact_index[guid]; has {
        delete(old.artifact)
        delete(old.settings)
    }
    _artifact_index[guid] = _Artifact_Entry{
        artifact = strings.clone(key),
        mtime    = mtime,
        size     = size,
        settings = strings.clone(settings_hex),
    }
    _artifact_index_dirty = true
}

@(private = "file")
_artifact_index_save :: proc() {
    if !_artifact_index_dirty || _artifact_index_batch do return
    _artifact_index_dirty = false

    raw := make(map[string]_Artifact_Entry, len(_artifact_index), context.temp_allocator)
    for guid, e in _artifact_index {
        raw[uuid.to_string(guid, context.temp_allocator)] = e
    }
    opts := json.Marshal_Options{
        spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
        sort_maps_by_key = true,
    }
    data, merr := json.marshal(raw, opts, context.temp_allocator)
    if merr != nil do return
    os.make_directory(LIBRARY_DIR)
    _ = os.write_entire_file(ARTIFACT_DB_PATH, data)
}

// Drops entries whose asset no longer exists, so the artifact sweep below can
// collect their files. Editor-only in practice (the game has no full db walk).
@(private = "file")
_artifact_index_prune :: proc() {
    context.allocator = runtime.default_allocator() // index strings live there
    to_drop := make([dynamic]uuid.Identifier, context.temp_allocator)
    for guid in _artifact_index {
        if _, has := asset_db.guid_to_path[guid]; !has {
            append(&to_drop, guid)
        }
    }
    for guid in to_drop {
        e := _artifact_index[guid]
        delete(e.artifact)
        delete(e.settings)
        delete_key(&_artifact_index, guid)
        _artifact_index_dirty = true
    }
}

// --- Content keys -------------------------------------------------------------

@(private = "file")
_settings_hash_hex :: proc(settings: ImportSettings) -> string {
    data, merr := json.marshal(settings, {spec = .JSON}, context.temp_allocator)
    if merr != nil do return "0000000000000000"
    return fmt.tprintf("%016x", xxh.XXH3_64(data))
}

// The artifact key: 128-bit hash of the source bytes, seeded by everything
// else that shapes the importer's output. Same inputs -> same key, on any
// machine.
@(private = "file")
_artifact_key :: proc(content: []byte, settings: ImportSettings, importer: string) -> string {
    header := fmt.tprintf("moonhug-artifact|%s|v%d|f%d|s%s",
        importer, _importer_version(importer), _ARTIFACT_FORMAT_VERSION,
        _settings_hash_hex(settings))
    seed := xxh.XXH3_64(transmute([]u8)header)
    return fmt.tprintf("%032x", xxh.XXH3_128_with_seed(content, seed))
}

// "Library/Artifacts/<first 2 hex>/<key>.bin" — Unity's fan-out layout.
@(private = "file")
_artifact_key_path :: proc(key: string, allocator := context.allocator) -> string {
    return fmt.aprintf("%s/%s/%s.bin", ARTIFACTS_DIR, key[:2], key, allocator = allocator)
}

_run_import :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    ext := filepath.ext(source_path)
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp":
        return _import_texture(source_path, artifact_path, settings)
    case ".mp3", ".wav", ".ogg":
        return _import_audio(source_path, artifact_path, settings)
    case ".glb", ".gltf":
        return _import_mesh(source_path, artifact_path, settings)
    case ".glsl":
        return _import_shader(source_path, artifact_path, settings)
    }
    return false
}

_ensure_artifact_dir :: proc(artifact_path: string) {
    // Create every missing segment — os.make_directory is non-recursive, so a
    // bare "library/artifacts" fails outright when "library" itself is absent
    // (fresh checkout, cleaned workspace).
    dir := filepath.dir(artifact_path)
    for i := 0; i <= len(dir); i += 1 {
        if i == len(dir) || dir[i] == '/' {
            if i > 0 do os.make_directory(dir[:i])
        }
    }
}

// Garbage collection: an artifact file no index entry references is dead —
// delete it. Files sitting directly in Artifacts/ predate the fan-out layout
// and are never referenced, so they collect the same way. Mesh part files
// ("<key>_m<i>.bin") live and die with their primary key.
_cleanup_stale_artifacts :: proc() {
    referenced := make(map[string]bool, len(_artifact_index), context.temp_allocator)
    for _, e in _artifact_index {
        referenced[e.artifact] = true
    }

    removed := 0
    sweep_dir :: proc(dir: string, referenced: ^map[string]bool, removed: ^int, top: bool) {
        handle, err := os.open(dir)
        if err != nil do return
        defer os.close(handle)
        entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
        if read_err != nil do return
        defer os.file_info_slice_delete(entries, context.temp_allocator)

        for entry in entries {
            full_path, _ := filepath.join({dir, entry.name}, context.temp_allocator)
            if entry.type == .Directory {
                if top do sweep_dir(full_path, referenced, removed, false)
                continue
            }
            if !strings.has_suffix(entry.name, ".bin") do continue
            key := strings.trim_suffix(entry.name, ".bin")
            if m := strings.last_index(key, "_m"); m >= 0 {
                key = key[:m]
            }
            if top || !referenced[key] {
                os.remove(full_path)
                removed^ += 1
            }
        }
    }
    sweep_dir(ARTIFACTS_DIR, &referenced, &removed, true)

    if removed > 0 {
        fmt.printf("[Pipeline] Removed %d stale artifact(s)\n", removed)
    }
}

// The asset's CURRENT artifact file, resolved through the index. Returns an
// owned string — empty (still owned) when the asset has no artifact.
_artifact_path :: proc(guid: uuid.Identifier) -> string {
    _artifact_index_ensure()
    if e, has := _artifact_index[guid]; has {
        return _artifact_key_path(e.artifact)
    }
    return strings.clone("")
}

// Public resolve for tooling (thumbnail/preview caches). Temp-allocated path.
asset_pipeline_artifact_path :: proc(guid: Asset_GUID) -> (path: string, ok: bool) {
    _artifact_index_ensure()
    if e, has := _artifact_index[uuid.Identifier(guid)]; has {
        return _artifact_key_path(e.artifact, context.temp_allocator), true
    }
    return "", false
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

    // Metas written before pixels_per_unit existed carry 0 — normalize to
    // the default so old textures keep their size.
    if ts, is_tex := result.settings.(TextureSettings); is_tex && ts.pixels_per_unit <= 0 {
        ts.pixels_per_unit = PIXELS_PER_UNIT
        result.settings = ts
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

    importer_name := _importer_for_extension(ext)

    new_meta := ImportMeta{
        guid     = guid_str,
        importer = importer_name,
        settings = settings_for_extension(ext),
    }

    _write_import_meta(meta_path, new_meta)
}
