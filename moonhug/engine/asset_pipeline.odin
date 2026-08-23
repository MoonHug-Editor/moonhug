package engine

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:encoding/json"
import "core:encoding/uuid"
import "base:runtime"

// The asset pipeline's READ half: the artifact index, meta/settings reading,
// artifact path resolution. The WRITE half — scanning, importing, meta
// writing — lives in moonhug:engine_editor/asset_pipeline and never links
// into a game binary: the app consumes what the editor produced.
//
// Unity's Library model: everything under library/ is derived data — safe to
// delete, rebuilt from assets + metas on the next run, never a source of
// truth. Import artifacts are CONTENT-ADDRESSED: the artifact key hashes every
// input that shapes the output (source bytes, import settings, importer
// version, artifact format version), so invalidation is automatic — changing
// any input is a different key, and toggling a setting back is a cache HIT on
// the old artifact, not a re-import. ArtifactDB.json maps guid -> current
// artifact key plus the file stamp and settings hash that make the per-scan
// freshness check cheap (no rehash of unchanged files).
LIBRARY_DIR      :: "library"
ARTIFACTS_DIR    :: "library/artifacts" // Artifacts/<first 2 hex>/<32-hex key>.bin
ARTIFACT_DB_PATH :: "library/artifact_db.json"

// A meta file's identity + import half. Settings materialize from the
// settings object's own __type_guid (every written meta carries one), so
// reading needs no importer registry — the game binary has none.
ImportMeta :: struct {
    guid:     string,
    importer: string,
    settings: any, // typed settings instance (nil = none)
}

// Overlays a parsed settings object onto a typed instance: present keys
// overwrite, absent keys keep the instance's defaults (this is what lets old
// metas pick up defaults for fields added later).
_settings_overlay :: proc(settings: any, v: json.Value) -> bool {
    bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
    if merr != nil do return false
    ptr_tid, pok := get_pointer_typeid_by_typeid(settings.id)
    if !pok do return false
    pp := settings.data
    return json.unmarshal_any(bytes, any{&pp, ptr_tid}) == nil
}

// A typed settings instance from a guid-tagged settings JSON object:
// defaults first (the type's registered factory), then overlay. Empty `any`
// when the object carries no known __type_guid.
_settings_from_value :: proc(v: json.Value, allocator := context.allocator) -> any {
    obj, is_obj := v.(json.Object)
    if !is_obj do return {}
    tg, tok := obj["__type_guid"].(json.String)
    if !tok do return {}
    guid, gerr := uuid.read(string(tg))
    if gerr != nil do return {}
    if get_typeid_by_guid(guid) == nil do return {}
    context.allocator = allocator
    settings := create_instance_by_guid(guid)
    if settings.data == nil do return {}
    _settings_overlay(settings, v)
    return settings
}

// The typed settings instance for an asset, allocated on `allocator` (the
// caller owns it — `free(result.data)` when done). Type-assert the result:
// `ts := settings.(TextureSettings)`.
asset_pipeline_get_settings :: proc(source_path: string, allocator := context.allocator) -> (any, bool) {
    // Catalog pipeline: settings are baked into the catalog — no .meta exists
    // in an exported data dir.
    if asset_db.pipeline == .Catalog {
        guid, gok := asset_db.path_to_guid[source_path]
        if !gok do return {}, false
        blob, has := _catalog_settings[guid]
        if !has do return {}, false
        prev := context.allocator
        context.allocator = context.temp_allocator
        root, perr := json.parse(transmute([]u8)blob, .JSON, true)
        context.allocator = prev
        if perr != nil do return {}, false
        settings := _settings_from_value(root, allocator)
        return settings, settings.data != nil
    }

    meta_path := strings.concatenate({source_path, ".meta"}, context.temp_allocator)

    import_meta := _read_import_meta(meta_path, allocator)
    if import_meta.guid == "" do return {}, false
    delete(import_meta.guid)

    return import_meta.settings, import_meta.settings.data != nil
}

// Per-guid settings JSON under the catalog pipeline (asset_db_init_from_catalog seeds it).
_catalog_settings: map[uuid.Identifier]string

_catalog_settings_set :: proc(guid: uuid.Identifier, blob: string) {
    context.allocator = runtime.default_allocator()
    if _catalog_settings == nil do _catalog_settings = make(map[uuid.Identifier]string)
    if old, has := _catalog_settings[guid]; has do delete(old)
    _catalog_settings[guid] = strings.clone(blob)
}

// --- Artifact index (library/artifact_db.json) --------------------------------

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

// The current entry for a guid — strings are BORROWED views into the index
// (valid until the entry is replaced). The import driver's freshness check.
_artifact_index_lookup :: proc(guid: uuid.Identifier) -> (entry: _Artifact_Entry, ok: bool) {
    _artifact_index_ensure()
    e, has := _artifact_index[guid]
    return e, has
}

_artifact_index_batch_set :: proc(on: bool) {
    _artifact_index_batch = on
}

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

@(private = "file")
// Where artifact files live. The default is the working tree's library — a
// relocatable-catalog boot retargets it at the export's artifacts dir
// (asset_db_init_from_catalog), and every resolve below follows.
// asset_db_shutdown resets it via _catalog_pipeline_reset.
_artifact_dir := ARTIFACTS_DIR
@(private = "file") _artifact_dir_owned: bool

_artifact_dir_set :: proc(dir: string) {
    context.allocator = runtime.default_allocator()
    if _artifact_dir_owned do delete(_artifact_dir)
    _artifact_dir = strings.clone(dir)
    _artifact_dir_owned = true
}

// Drop every catalog-pipeline override: artifact resolution back to the working
// tree, baked settings gone. Called from asset_db_shutdown so a later live
// init (tests, editor after a catalog-pipeline tool run) starts clean.
_catalog_pipeline_reset :: proc() {
    context.allocator = runtime.default_allocator()
    if _artifact_dir_owned {
        delete(_artifact_dir)
        _artifact_dir = ARTIFACTS_DIR
        _artifact_dir_owned = false
    }
    for _, blob in _catalog_settings do delete(blob)
    delete(_catalog_settings)
    _catalog_settings = nil
}

// "library/artifacts/<first 2 hex>/<key>.bin" — Unity's fan-out layout.
_artifact_key_path :: proc(key: string, allocator := context.allocator) -> string {
    return fmt.aprintf("%s/%s/%s.bin", _artifact_dir, key[:2], key, allocator = allocator)
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

// The raw content-address key for a guid (the catalog writer snapshots these).
// Temp-allocated.
asset_pipeline_artifact_key :: proc(guid: Asset_GUID) -> (key: string, ok: bool) {
    _artifact_index_ensure()
    if e, has := _artifact_index[uuid.Identifier(guid)]; has {
        return strings.clone(e.artifact, context.temp_allocator), true
    }
    return "", false
}

// Catalog pipeline: the catalog is the artifact index — mark it loaded and fill it
// directly, so _artifact_index_ensure never reads artifact_db.json over it.
// Stamps stay zero: they only feed the import freshness check, and imports
// are refused under the catalog pipeline.
_artifact_index_seed :: proc(guid: uuid.Identifier, key: string) {
    _artifact_index_loaded = true
    if _artifact_index == nil {
        context.allocator = runtime.default_allocator()
        _artifact_index = make(map[uuid.Identifier]_Artifact_Entry)
    }
    _artifact_index_set(guid, key, 0, 0, "")
    _artifact_index_dirty = false // seeded entries never write back to disk
}

// Public resolve for tooling (thumbnail/preview caches). Temp-allocated path.
asset_pipeline_artifact_path :: proc(guid: Asset_GUID) -> (path: string, ok: bool) {
    _artifact_index_ensure()
    if e, has := _artifact_index[uuid.Identifier(guid)]; has {
        return _artifact_key_path(e.artifact, context.temp_allocator), true
    }
    return "", false
}

// Reimport hooks: guid-keyed caches (textures, package-owned asset caches)
// register to evict their entry when an asset's artifact changes. Fired on
// every import that did work (importer ran or the index re-pointed).
Reimport_Hook :: proc(guid: Asset_GUID)

_reimport_hooks: [dynamic]Reimport_Hook

asset_pipeline_add_reimport_hook :: proc(hook: Reimport_Hook) {
    // Registry state never borrows the caller's allocator (same rule as
    // component_register — tests hand out scoped tracking allocators).
    context.allocator = runtime.default_allocator()
    append(&_reimport_hooks, hook)
}

_notify_reimported :: proc(guid: uuid.Identifier) {
    for hook in _reimport_hooks do hook(Asset_GUID(guid))
}

// Loader self-heal seam: a loader that finds its artifact missing or
// unparseable (fresh clone, cleaned library/, artifact format bump — stamps
// alone never catch a format bump) asks for an import through this. The
// import driver installs it (engine_editor); nil in a game binary, where a
// bad artifact is a load error, never repair work.
_import_request: proc(source_path: string, force: bool) -> bool

asset_pipeline_set_import_request :: proc(p: proc(source_path: string, force: bool) -> bool) {
    _import_request = p
}

asset_pipeline_request_import :: proc(source_path: string, force: bool) -> bool {
    if _import_request == nil do return false
    return _import_request(source_path, force)
}

// guid is cloned (caller deletes), the settings instance lives on `allocator`
// (materialized from the settings object's __type_guid — no importer registry).
_read_import_meta :: proc(meta_path: string, allocator := context.temp_allocator) -> ImportMeta {
    data, read_err := os.read_entire_file(meta_path, context.temp_allocator)
    if read_err != nil do return {}

    prev := context.allocator
    context.allocator = context.temp_allocator
    root, perr := json.parse(data, .JSON, true)
    context.allocator = prev
    if perr != nil do return {}
    obj, is_obj := root.(json.Object)
    if !is_obj do return {}

    guid_v, g_ok := obj["guid"].(json.String)
    if !g_ok || string(guid_v) == "" do return {}
    importer := ""
    if imp_v, i_ok := obj["importer"].(json.String); i_ok do importer = string(imp_v)

    meta := ImportMeta{
        guid     = strings.clone(string(guid_v)),
        importer = importer,
    }
    if sv, has := obj["settings"]; has {
        meta.settings = _settings_from_value(sv, allocator)
    }
    return meta
}
