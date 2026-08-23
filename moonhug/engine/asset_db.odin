package engine

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:slice"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:path/filepath"
import "core:encoding/json"
import "core:encoding/uuid"
import "log"

// Which pipeline feeds the AssetDB (docs/AssetPipeline.md "Asset catalog and
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

AssetDB :: struct {
    guid_to_path: map[uuid.Identifier]string,
    path_to_guid: map[string]uuid.Identifier,
    root_path:    string,
    pipeline:     Asset_Pipeline_Kind,
    // The catalog's pinned boot scene ({} = none) — what the app loads under
    // the catalog pipeline when no scene argument is given.
    boot_scene:   Asset_GUID,

    // Root-info index for the object picker (docs/ObjectPicker.md): per scene
    // asset, its root transform; assets_by_type answers "scene assets whose
    // ROOT has component X" without parsing files. TypeKey keys are safe here
    // because the index is runtime-only, rebuilt from type GUIDs on change.
    root_info:      map[Asset_GUID]Asset_Root_Info,
    // Values are complete persistent pointers into the asset (guid + the root
    // component's local_id — the root transform's own lid for .Transform), so
    // a picker assignment IS the PPtr, same as Unity's guid+fileID.
    assets_by_type: map[TypeKey][dynamic]PPtr,

    // Refresh snapshot (Unity's SourceAssetDB idea): per path, the stamp seen
    // at the last refresh. asset_db_refresh diffs the tree against this and
    // touches ONLY what changed — no polling, no OS watcher; the caller
    // decides when to refresh (editor: on window focus + own file operations).
    // Keys are owned clones. Directories get a zero stamp: tracked for
    // create/delete only (their mtimes churn with every child change).
    file_state: map[string]Asset_File_Stamp,
}

Asset_Root_Info :: struct {
    root_local_id: Local_ID,
    root_name:     string, // owned
    is_variant:    bool,   // file inherits a base (root NS with transform_parent == 0)
    base_prefab:   Asset_GUID, // is_variant only: the Base Prefab it inherits from
}

Asset_File_Stamp :: struct {
    mtime: time.Time,
    size:  i64,
}

asset_db: AssetDB

MetaFile :: struct {
    guid: string,
}

// Installed packages (docs/Plugins.md): every folder in packages/ (a cwd
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
// editor-side (engine_editor/pipeline) — with no refresh proc installed (a
// binary without the pipeline) the maps just start empty.
asset_db_init :: proc(root: string) {
    asset_db.root_path = strings.clone(root)
    asset_db.guid_to_path = make(map[uuid.Identifier]string)
    asset_db.path_to_guid = make(map[string]uuid.Identifier)
    asset_db.root_info = make(map[Asset_GUID]Asset_Root_Info)
    asset_db.assets_by_type = make(map[TypeKey][dynamic]PPtr)
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
    for _, v in asset_db.guid_to_path {
        delete(v)
    }
    delete(asset_db.guid_to_path)
    delete(asset_db.path_to_guid)
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

// Incremental refresh (Unity model): enumerate the tree (stat only), diff
// against file_state, and process only the deltas — new assets get metas +
// registration, changed scene assets re-index, deleted assets unregister and
// their orphaned metas are removed. Renames arrive as delete+create; the meta
// travels with the file (project view moves it), so the guid stays stable.
// Fired by asset_db_refresh for every created or modified source path.
// Packages register cache invalidation for their asset extensions here
// (the animation package drops edited .anim clips), the way built-in
// material/shader caches are called directly above.
// The scan/refresh machinery is editor-side (engine_editor/asset_scan.odin):
// game binaries run the catalog pipeline only and never scan. Engine code
// that needs a refresh after writing an asset (scene_save) requests one
// through this seam — installed by the editor, nil in the app.
_refresh_proc: proc()

asset_db_set_refresh_proc :: proc(p: proc()) {
    _refresh_proc = p
}

asset_db_request_refresh :: proc() {
    if _refresh_proc != nil do _refresh_proc()
}

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

_asset_removed :: proc(path: string) {
    guid, ok := asset_db.path_to_guid[path]
    if !ok do return
    material_path_changed(path)
    if strings.has_suffix(path, ".glsl") {
        shader_unload(Asset_GUID(guid))
    }
    stored := asset_db.guid_to_path[guid] // the one owned clone (used as key AND value)
    delete_key(&asset_db.path_to_guid, path)
    delete_key(&asset_db.guid_to_path, guid)
    _index_remove(Asset_GUID(guid))
    delete(stored)
}

_reindex_if_scene :: proc(path: string) {
    if !strings.has_suffix(path, ".scene") do return
    guid, ok := asset_db.path_to_guid[path]
    if !ok do return
    _index_remove(Asset_GUID(guid))
    _index_scene_asset(Asset_GUID(guid), path)
}

// Scene assets whose root transform carries a component of `key`, as complete
// cross-asset PPtrs (guid + root component local_id). Empty when none.
asset_db_assets_with_root_type :: proc(key: TypeKey) -> []PPtr {
    arr, ok := asset_db.assets_by_type[key]
    if !ok do return nil
    return arr[:]
}

asset_db_get_root_info :: proc(guid: Asset_GUID) -> (Asset_Root_Info, bool) {
    info, ok := asset_db.root_info[guid]
    return info, ok
}

// The refresh-tracked file stamp (mtime + size) — a cheap freshness key for
// caches derived from asset contents (the editor's thumbnails).
asset_db_get_stamp :: proc(path: string) -> (Asset_File_Stamp, bool) {
    stamp, ok := asset_db.file_state[path]
    return stamp, ok
}

_index_add :: proc(key: TypeKey, guid: Asset_GUID, local_id: Local_ID) {
    arr := asset_db.assets_by_type[key]
    append(&arr, PPtr{local_id = local_id, guid = guid})
    asset_db.assets_by_type[key] = arr
}

_index_remove :: proc(guid: Asset_GUID) {
    if info, ok := asset_db.root_info[guid]; ok {
        delete(info.root_name)
        delete_key(&asset_db.root_info, guid)
    }
    // Collect keys first — mutating values while iterating a map is unsafe.
    keys := make([dynamic]TypeKey, context.temp_allocator)
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

_index_scene_asset :: proc(guid: Asset_GUID, path: string) {
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil do return

    // Externally changed bytes (git checkout, other tools): refresh the
    // scene_lib cache and re-propagate to loaded scenes, exactly like an
    // editor save would. The save path itself already committed identical
    // bytes, so the equality check keeps it from re-propagating twice.
    if cached, has := scene_lib[guid]; has {
        if string(cached) != string(data) {
            _prefab_bytes_committed(guid, data)
        }
    }

    sf: SceneFile
    if scene_file_unmarshal(data, &sf) != nil do return

    is_variant := false
    base_prefab := Asset_GUID{}
    for &ns in sf.nested_scenes {
        if ns.transform_parent == 0 {
            is_variant = true
            base_prefab = ns.source_prefab
            break
        }
    }
    if is_variant {
        // A variant file has no root transform record of its own (sf.root
        // names the BASE root; only added content is stored). Index the
        // FLATTENED form instead, so variants get root info and inherited
        // root components like any other scene asset.
        scene_file_destroy(&sf)
        flat, flat_owned := _prefab_resolved_bytes(guid)
        if flat == nil do return
        cpy := make([]byte, len(flat), context.temp_allocator)
        copy(cpy, flat)
        if flat_owned do delete(flat)
        sf = {}
        if scene_file_unmarshal(cpy, &sf) != nil do return
    }
    defer scene_file_destroy(&sf)

    root: ^Transform
    for &t in sf.transforms {
        if t.local_id == sf.root {
            root = &t
            break
        }
    }
    if root == nil do return

    asset_db.root_info[guid] = {
        root_local_id = sf.root,
        root_name     = strings.clone(root.name),
        is_variant    = is_variant,
        base_prefab   = base_prefab,
    }
    // Every scene asset's root IS a transform.
    _index_add(.Transform, guid, sf.root)

    root_lids := make(map[Local_ID]bool, context.temp_allocator)
    for c in root.components {
        root_lids[c.local_id] = true
    }
    if len(root_lids) == 0 do return

    // Typed component arrays, found by reflecting over SceneFile (component
    // structs start with CompData; non-component record arrays are skipped
    // explicitly). Keeps working when the generator adds component types.
    ti := runtime.type_info_base(type_info_of(SceneFile)).variant.(runtime.Type_Info_Struct)
    for i in 0 ..< ti.field_count {
        ftype := runtime.type_info_base(ti.types[i])
        dyn, is_dyn := ftype.variant.(runtime.Type_Info_Dynamic_Array)
        if !is_dyn do continue
        elem_id := dyn.elem.id
        if elem_id == typeid_of(Transform) || elem_id == typeid_of(NestedScene) || elem_id == typeid_of(Breadcrumb) do continue
        key, kok := get_type_key_by_typeid(elem_id)
        if !kok do continue // e.g. json.Value (ext components, handled below)
        arr := cast(^runtime.Raw_Dynamic_Array)(rawptr(uintptr(&sf) + ti.offsets[i]))
        for j in 0 ..< arr.len {
            base := cast(^CompData)(uintptr(arr.data) + uintptr(j) * uintptr(dyn.elem.size))
            if root_lids[base.local_id] {
                _index_add(key, guid, base.local_id)
                break
            }
        }
    }

    // External (app-package) components: type from the "__type" guid record.
    for &v in sf.components {
        desc, dok := _ext_desc_for_value(v)
        if !dok do continue
        obj := v.(json.Object)
        bobj, has_base := obj["base"].(json.Object)
        if !has_base do continue
        lid: Local_ID
        #partial switch n in bobj["local_id"] {
        case json.Integer: lid = Local_ID(n)
        case json.Float:   lid = Local_ID(n)
        }
        if root_lids[lid] {
            _index_add(desc.type_key, guid, lid)
        }
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
