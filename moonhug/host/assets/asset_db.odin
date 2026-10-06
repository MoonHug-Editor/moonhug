package assets

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:path/filepath"
import "core:encoding/json"
import "core:encoding/uuid"
import "moonhug:host/log"
import core "moonhug:host/core"

// Which pipeline feeds the AssetDB (docs/core/AssetPipeline.md "Asset catalog and
// builds"). Both end at the same loaders — they differ in where content
// comes from.
Asset_Pipeline_Kind :: enum {
    // Dev, the zero value: scan assets/, read metas, import lazily.
    Import,
    // Everything resolves from a catalog file (asset_db_init_from_catalog):
    // refresh no-ops and runtime imports are refused — the catalog is
    // authoritative, a miss is an error, never repair work.
    Catalog,
}

// A sub-asset that carries its OWN guid (a clip inside a model): the asset
// that owns it, its id in that asset's sub-asset id space, and the picker
// kind it answers to (the extension a field's `ext:` tag would name, "anim").
// The sub guid is also in guid_to_path, mapped to the OWNER's path, so path
// lookups, the catalog and the export's guid harvest treat it as an asset
// without knowing it is nested. path_to_guid stays one-to-one.
Sub_Asset_Ref :: struct {
    owner: core.Asset_GUID,
    id:    core.Local_ID,
    kind:  string, // static literal, never freed
}

AssetDB :: struct {
    guid_to_path: map[uuid.Identifier]string,
    path_to_guid: map[string]uuid.Identifier,
    subs:         map[uuid.Identifier]Sub_Asset_Ref,
    root_path:    string,
    pipeline:     Asset_Pipeline_Kind,
    // The catalog's pinned boot scene ({} = none) — what the app loads under
    // the catalog pipeline when no scene argument is given.
    boot_scene:   core.Asset_GUID,

    // Root-info index for the object picker (docs/core/ObjectPicker.md): per scene
    // asset, its root transform; assets_by_type answers "scene assets whose
    // ROOT has component X" without parsing files. TypeKey keys are safe here
    // because the index is runtime-only, rebuilt from type GUIDs on change.
    root_info:      map[core.Asset_GUID]Asset_Root_Info,
    // Values are complete persistent pointers into the asset (guid + the root
    // component's local_id — the root transform's own lid for .Transform), so
    // a picker assignment IS the PPtr, same as Unity's guid+fileID.
    assets_by_type: map[core.TypeKey][dynamic]core.PPtr,

    // Refresh snapshot (Unity's SourceAssetDB idea): per path, the stamp seen
    // at the last refresh. asset_db_refresh diffs the tree against this and
    // touches ONLY what changed — no polling, no OS watcher; the caller
    // decides when to refresh (editor: on window focus + own file operations).
    // Keys are owned clones. Directories get a zero stamp: tracked for
    // create/delete only (their mtimes churn with every child change).
    file_state: map[string]Asset_File_Stamp,
}

Asset_Root_Info :: struct {
    root_local_id: core.Local_ID,
    root_name:     string, // owned
    is_variant:    bool,   // file inherits a base (root NS with transform_parent == 0)
    base_prefab:   core.Asset_GUID, // is_variant only: the Base Prefab it inherits from
}

Asset_File_Stamp :: struct {
    mtime: time.Time,
    size:  i64,
}

asset_db: AssetDB

MetaFile :: struct {
    guid: string,
}

// Installed packages (docs/core/Plugins.md): every folder in packages/ (a cwd
// sibling of the assets root) is an installed package, and its assets/
// subtree is an additional asset-db root. The assets/ folder is ENSURED
// (created if missing) so package roots always resolve.
ASSET_DB_PACKAGES_DIR :: "packages"

Asset_Package_Root :: struct {
    name:        string, // package folder name
    assets_path: string, // "packages/<name>/assets"
}

// Temp-allocated, sorted by name. Empty when packages/ doesn't exist (tests,
// bare projects).
asset_db_package_roots :: proc() -> []Asset_Package_Root {
    handle, err := os.open(ASSET_DB_PACKAGES_DIR)
    if err != nil do return nil
    defer os.close(handle)
    entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil do return nil
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    roots := make([dynamic]Asset_Package_Root, context.temp_allocator)
    for entry in entries {
        if strings.has_prefix(entry.name, ".") do continue
        // A symlinked package (samples installed via symlink) reads as
        // .Symlink here — follow it, everything below resolves normally.
        if entry.type != .Directory {
            full, _ := filepath.join({ASSET_DB_PACKAGES_DIR, entry.name}, context.temp_allocator)
            if entry.type != .Symlink || !os.is_dir(full) do continue
        }
        assets_path, _ := filepath.join({ASSET_DB_PACKAGES_DIR, entry.name, "assets"}, context.temp_allocator)
        os.make_directory(assets_path) // ensure — no-op when it exists
        append(&roots, Asset_Package_Root{name = strings.clone(entry.name, context.temp_allocator), assets_path = assets_path})
    }
    slice.sort_by(roots[:], proc(a, b: Asset_Package_Root) -> bool { return a.name < b.name })
    return roots[:]
}

// Storage init + a scan request through the refresh seam. The scan itself is
// editor-side (editor/assets) — with no refresh proc installed (a
// binary without the pipeline) the maps just start empty.
asset_db_init :: proc(root: string) {
    asset_db.root_path = strings.clone(root)
    asset_db.guid_to_path = make(map[uuid.Identifier]string)
    asset_db.path_to_guid = make(map[string]uuid.Identifier)
    asset_db.root_info = make(map[core.Asset_GUID]Asset_Root_Info)
    asset_db.assets_by_type = make(map[core.TypeKey][dynamic]core.PPtr)
    asset_db.file_state = make(map[string]Asset_File_Stamp)
    asset_db_request_refresh()
}

asset_db_shutdown :: proc() {
    _catalog_pipeline_reset()
    _free_maps()
    _free_root_index()
    for path in asset_db.file_state {
        delete(path)
    }
    delete(asset_db.file_state)
    delete(asset_db.root_path)
    // Zero everything: scene_save's refresh trigger tests root_path != "" —
    // a dangling freed string here would send refreshes walking garbage in
    // any later db-less context (test pollution).
    asset_db = {}
}

_free_maps :: proc() {
    // Sub-asset entries own their own clone of the owner path, freed here
    // with everything else in guid_to_path.
    for _, v in asset_db.guid_to_path {
        delete(v)
    }
    delete(asset_db.guid_to_path)
    delete(asset_db.path_to_guid)
    delete(asset_db.subs)
}

_free_root_index :: proc() {
    for _, info in asset_db.root_info {
        delete(info.root_name)
    }
    delete(asset_db.root_info)
    for _, arr in asset_db.assets_by_type {
        delete(arr)
    }
    delete(asset_db.assets_by_type)
    asset_db.root_info = nil
    asset_db.assets_by_type = nil
}

// The scan/refresh machinery is editor-side (editor/assets/asset_scan.odin):
// game binaries run the catalog pipeline only and never scan. Engine code
// that needs a refresh after writing an asset (scene_save) requests one
// through this seam, installed by the editor and nil in the app.
_refresh_proc: proc()

asset_db_set_refresh_proc :: proc(p: proc()) {
    _refresh_proc = p
}

asset_db_request_refresh :: proc() {
    if _refresh_proc != nil do _refresh_proc()
}

// Fired by asset_db_refresh for every created or modified source path, after
// the evict hooks. Packages register cache invalidation for their asset
// extensions here (the animation package drops edited .anim clips).
Path_Changed_Hook :: proc(path: string)

_path_changed_hooks: [dynamic]Path_Changed_Hook

asset_db_add_path_changed_hook :: proc(hook: Path_Changed_Hook) {
    for h in _path_changed_hooks {
        if h == hook do return
    }
    // Registry state never borrows the caller's allocator (same rule as
    // asset_pipeline_add_reimport_hook — tests hand out scoped tracking
    // allocators).
    context.allocator = runtime.default_allocator()
    append(&_path_changed_hooks, hook)
}

// Runs once per asset that left the project in a refresh: deleted, not
// renamed or moved (a rename keeps its guid under a new path, so it never
// fires). `path` is where the asset was. Editor state keyed by the guid,
// such as an open asset document and its undo steps, drops here.
Asset_Gone_Hook :: proc(guid: core.Asset_GUID, path: string)

_asset_gone_hooks: [dynamic]Asset_Gone_Hook

asset_db_add_asset_gone_hook :: proc(hook: Asset_Gone_Hook) {
    for h in _asset_gone_hooks {
        if h == hook do return
    }
    context.allocator = runtime.default_allocator()
    append(&_asset_gone_hooks, hook)
}

// Drops a cache entry derived from the asset at `path`. Runs for every
// changed path in a refresh, before the path-changed hooks, and for every
// removed asset while its guid still resolves. The engine's material and
// shader caches register here at @(init). Each hook checks the extension
// itself.
Evict_Hook :: proc(path: string)

_evict_hooks: [dynamic]Evict_Hook

asset_db_add_evict_hook :: proc(hook: Evict_Hook) {
    for h in _evict_hooks {
        if h == hook do return
    }
    context.allocator = runtime.default_allocator()
    append(&_evict_hooks, hook)
}

asset_db_run_evict_hooks :: proc(path: string) {
    for hook in _evict_hooks do hook(path)
}

_asset_removed :: proc(path: string) {
    guid, ok := asset_db.path_to_guid[path]
    if !ok do return
    asset_db_run_evict_hooks(path)
    stored := asset_db.guid_to_path[guid] // the one owned clone (used as key AND value)
    _unregister_subs_of(core.Asset_GUID(guid))
    delete_key(&asset_db.path_to_guid, path)
    delete_key(&asset_db.guid_to_path, guid)
    _index_remove(core.Asset_GUID(guid))
    delete(stored)
}

// --- Sub-asset guids -----------------------------------------------------------

asset_db_get_sub :: proc(guid: core.Asset_GUID) -> (Sub_Asset_Ref, bool) {
    ref, ok := asset_db.subs[uuid.Identifier(guid)]
    return ref, ok
}

// The guid of `owner`'s sub-asset `id`, for a drop from the project view,
// which carries (owner, id). Linear: a model has tens of clips, not thousands.
asset_db_sub_guid :: proc(owner: core.Asset_GUID, id: core.Local_ID) -> (core.Asset_GUID, bool) {
    for guid, ref in asset_db.subs {
        if ref.owner == owner && ref.id == id do return core.Asset_GUID(guid), true
    }
    return {}, false
}

// A fresh guid for an importer minting sub-asset identities.
asset_db_new_guid :: proc() -> core.Asset_GUID {
    return core.Asset_GUID(_generate_guid())
}

// Idempotent: re-registering the same sub is a no-op, a sub that moved to a
// different owner is re-pointed.
_register_sub :: proc(owner_path: string, owner: core.Asset_GUID, sub: core.Asset_GUID, id: core.Local_ID, kind: string) {
    key := uuid.Identifier(sub)
    if ref, has := asset_db.subs[key]; has && ref.owner == owner && ref.id == id do return
    if stored, has := asset_db.guid_to_path[key]; has {
        if _, is_asset := asset_db.path_to_guid[stored]; is_asset && asset_db.path_to_guid[stored] == key {
            // A real asset already holds this guid. Never let a nested one shadow it.
            log.errorf("[AssetDB] sub-asset guid %s collides with asset %s — not registered", uuid.to_string(key, context.temp_allocator), stored)
            return
        }
        delete(stored)
    }
    asset_db.guid_to_path[key] = strings.clone(owner_path)
    asset_db.subs[key] = Sub_Asset_Ref{owner = owner, id = id, kind = kind}
}

_unregister_subs_of :: proc(owner: core.Asset_GUID) {
    gone := make([dynamic]uuid.Identifier, context.temp_allocator)
    for guid, ref in asset_db.subs do if ref.owner == owner do append(&gone, guid)
    for guid in gone {
        if stored, has := asset_db.guid_to_path[guid]; has {
            delete(stored)
            delete_key(&asset_db.guid_to_path, guid)
        }
        delete_key(&asset_db.subs, guid)
    }
}

// Registers the sub-asset guids an asset declares and drops the ones it no
// longer declares, so a removed sub stops resolving. `kind` is a static
// literal. The importer that owns the asset calls this (the mesh importer
// for model clips).
Sub_Asset_Decl :: struct {
    guid: core.Asset_GUID,
    id:   core.Local_ID,
}

asset_db_set_subs :: proc(path: string, kind: string, subs: []Sub_Asset_Decl) {
    raw, gok := asset_db.path_to_guid[path]
    if !gok do return
    owner := core.Asset_GUID(raw)
    _unregister_subs_of(owner)
    for sub in subs {
        if sub.guid == {} || sub.id == 0 do continue
        _register_sub(path, owner, sub.guid, sub.id, kind)
    }
}

// Indexers fill the root-info index from an asset's bytes. One registers per
// extension (the engine registers ".scene" at @(init)), and
// asset_db_reindex reads a file only when an indexer matches it.
Asset_Indexer :: proc(guid: core.Asset_GUID, path: string, data: []byte)

@(private = "file")
_Indexer_Entry :: struct {
    ext:  string, // static literal
    proc_: Asset_Indexer,
}

@(private = "file")
_indexers: [dynamic]_Indexer_Entry

asset_db_add_indexer :: proc(ext: string, indexer: Asset_Indexer) {
    for e in _indexers {
        if e.ext == ext && e.proc_ == indexer do return
    }
    context.allocator = runtime.default_allocator()
    append(&_indexers, _Indexer_Entry{ext = ext, proc_ = indexer})
}

// Clears the asset's index entries and runs the indexers registered for its
// extension. Called by the refresh for every created or modified path.
asset_db_reindex :: proc(path: string) {
    ext := filepath.ext(path)
    matched := false
    for e in _indexers do if e.ext == ext do matched = true
    if !matched do return
    guid, ok := asset_db.path_to_guid[path]
    if !ok do return
    _index_remove(core.Asset_GUID(guid))
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil do return
    for e in _indexers do if e.ext == ext do e.proc_(core.Asset_GUID(guid), path, data)
}

// One index entry: the asset's root carries a component of `key` whose local
// id is `local_id`.
Asset_Index_Entry :: struct {
    key:      core.TypeKey,
    local_id: core.Local_ID,
}

// Sets an asset's root info and its index entries. The indexer calls it once
// per asset, after asset_db_reindex cleared the old entries. The root name is
// cloned.
asset_db_index_set :: proc(guid: core.Asset_GUID, info: Asset_Root_Info, entries: ..Asset_Index_Entry) {
    if old, has := asset_db.root_info[guid]; has do delete(old.root_name)
    stored := info
    stored.root_name = strings.clone(info.root_name)
    asset_db.root_info[guid] = stored
    for e in entries do _index_add(e.key, guid, e.local_id)
}

// Scene assets whose root transform carries a component of `key`, as complete
// cross-asset PPtrs (guid + root component local_id). Empty when none.
asset_db_assets_with_root_type :: proc(key: core.TypeKey) -> []core.PPtr {
    arr, ok := asset_db.assets_by_type[key]
    if !ok do return nil
    return arr[:]
}

asset_db_get_root_info :: proc(guid: core.Asset_GUID) -> (Asset_Root_Info, bool) {
    info, ok := asset_db.root_info[guid]
    return info, ok
}

// The refresh-tracked file stamp (mtime + size) — a cheap freshness key for
// caches derived from asset contents (the editor's thumbnails).
asset_db_get_stamp :: proc(path: string) -> (Asset_File_Stamp, bool) {
    stamp, ok := asset_db.file_state[path]
    return stamp, ok
}

_index_add :: proc(key: core.TypeKey, guid: core.Asset_GUID, local_id: core.Local_ID) {
    arr := asset_db.assets_by_type[key]
    append(&arr, core.PPtr{local_id = local_id, guid = guid})
    asset_db.assets_by_type[key] = arr
}

_index_remove :: proc(guid: core.Asset_GUID) {
    if info, ok := asset_db.root_info[guid]; ok {
        delete(info.root_name)
        delete_key(&asset_db.root_info, guid)
    }
    // Collect keys first — mutating values while iterating a map is unsafe.
    keys := make([dynamic]core.TypeKey, context.temp_allocator)
    for key in asset_db.assets_by_type {
        append(&keys, key)
    }
    for key in keys {
        arr := asset_db.assets_by_type[key]
        for i := 0; i < len(arr); {
            if arr[i].guid == guid {
                unordered_remove(&arr, i)
            } else {
                i += 1
            }
        }
        asset_db.assets_by_type[key] = arr
    }
}

asset_db_get_path :: proc(guid: uuid.Identifier) -> (string, bool) {
    if path, ok := asset_db.guid_to_path[guid]; ok {
        return path, true
    }
    return "", false
}

asset_db_get_guid :: proc(path: string) -> (uuid.Identifier, bool) {
    if guid, ok := asset_db.path_to_guid[path]; ok {
        return guid, true
    }
    return {}, false
}

_register_asset :: proc(path: string, guid: uuid.Identifier) {
    // Idempotent: modified assets re-register on every refresh; blindly
    // re-cloning would desync the single owned clone shared by both maps.
    if existing, ok := asset_db.path_to_guid[path]; ok {
        if existing == guid do return
        // guid changed (meta edited externally) — drop the old registration.
        _asset_removed(path)
    }
    // Same guid at two paths (a copied package/asset WITH its metas): keep the
    // first registration and complain loudly — references would silently
    // resolve to whichever won otherwise.
    if other, taken := asset_db.guid_to_path[guid]; taken && other != path {
        guid_str := uuid.to_string(guid, context.temp_allocator)
        log.errorf("[AssetDB] duplicate guid %s: %s and %s — second one NOT registered (delete one .meta to mint a fresh guid)", guid_str, other, path)
        return
    }
    p := strings.clone(path)
    asset_db.guid_to_path[guid] = p
    asset_db.path_to_guid[p] = guid
}

_read_meta :: proc(meta_path: string) -> (uuid.Identifier, bool) {
    data, read_err := os.read_entire_file(meta_path, context.temp_allocator)
    if read_err != nil do return {}, false

    result: MetaFile
    unmarshal_err := json.unmarshal(data, &result)
    if unmarshal_err != nil {
        return {}, false
    }
    defer delete(result.guid)

    if result.guid == "" {
        return {}, false
    }

    id, parse_err := uuid.read(result.guid)
    if parse_err != nil {
        return {}, false
    }

    return id, true
}

_write_meta :: proc(meta_path: string, guid: uuid.Identifier) {
    guid_str := uuid.to_string(guid)
    defer delete(guid_str)
    meta := MetaFile{guid = guid_str}
    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }
    data, err := json.marshal(meta, opts)
    if err != nil do return
    defer delete(data)

    _ = os.write_entire_file(meta_path, data)
}

_generate_guid :: proc() -> uuid.Identifier {
    // uuid.generate_v4 asserts unless the context random generator is
    // cryptographic — supply one instead of depending on the caller's context
    // (the test runner installs a seeded, non-crypto generator).
    context.random_generator = crypto.random_generator()
    return uuid.generate_v4()
}
