package engine

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:encoding/json"
import "core:encoding/uuid"

AssetDB :: struct {
    guid_to_path: map[uuid.Identifier]string,
    path_to_guid: map[string]uuid.Identifier,
    root_path:    string,

    // Root-info index for the object picker (docs/ObjectPicker.md): per scene
    // asset, its root transform; assets_by_type answers "scene assets whose
    // ROOT has component X" without parsing files. TypeKey keys are safe here
    // because the index is runtime-only, rebuilt from type GUIDs every refresh.
    root_info:      map[Asset_GUID]Asset_Root_Info,
    assets_by_type: map[TypeKey][dynamic]Asset_GUID,
}

Asset_Root_Info :: struct {
    root_local_id: Local_ID,
    root_name:     string, // owned
}

asset_db: AssetDB

MetaFile :: struct {
    guid: string,
}

asset_db_init :: proc(root: string) {
    asset_db.root_path = strings.clone(root)
    asset_db.guid_to_path = make(map[uuid.Identifier]string)
    asset_db.path_to_guid = make(map[string]uuid.Identifier)
    asset_db_refresh()
}

asset_db_shutdown :: proc() {
    _free_maps()
    _free_root_index()
    delete(asset_db.root_path)
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

asset_db_refresh :: proc() {
    _free_maps()
    asset_db.guid_to_path = make(map[uuid.Identifier]string)
    asset_db.path_to_guid = make(map[string]uuid.Identifier)

    _scan_directory(asset_db.root_path)
    _cleanup_orphaned_metas(asset_db.root_path)
    _rebuild_root_index()

    fmt.printf("[AssetDB] Refreshed: %d assets indexed\n", len(asset_db.guid_to_path))
}

// Scene assets whose root transform carries a component of `key`. Empty when
// none (or before the first refresh).
asset_db_assets_with_root_type :: proc(key: TypeKey) -> []Asset_GUID {
    arr, ok := asset_db.assets_by_type[key]
    if !ok do return nil
    return arr[:]
}

asset_db_get_root_info :: proc(guid: Asset_GUID) -> (Asset_Root_Info, bool) {
    info, ok := asset_db.root_info[guid]
    return info, ok
}

_rebuild_root_index :: proc() {
    _free_root_index()
    asset_db.root_info = make(map[Asset_GUID]Asset_Root_Info)
    asset_db.assets_by_type = make(map[TypeKey][dynamic]Asset_GUID)
    for path, guid in asset_db.path_to_guid {
        if !strings.has_suffix(path, ".scene") do continue
        _index_scene_asset(Asset_GUID(guid), path)
    }
}

_index_add :: proc(key: TypeKey, guid: Asset_GUID) {
    arr := asset_db.assets_by_type[key]
    append(&arr, guid)
    asset_db.assets_by_type[key] = arr
}

_index_scene_asset :: proc(guid: Asset_GUID, path: string) {
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil do return
    sf: SceneFile
    if json.unmarshal(data, &sf) != nil do return
    defer scene_file_destroy(&sf)

    root: ^Transform
    for &t in sf.transforms {
        if t.local_id == sf.root {
            root = &t
            break
        }
    }
    if root == nil do return

    asset_db.root_info[guid] = {root_local_id = sf.root, root_name = strings.clone(root.name)}
    // Every scene asset's root IS a transform.
    _index_add(.Transform, guid)

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
                _index_add(key, guid)
                break
            }
        }
    }

    // External (app-package) components: type from the "__type" guid record.
    for &v in sf.ext_components {
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
            _index_add(desc.type_key, guid)
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

_scan_directory :: proc(dir_path: string) {
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
            _ensure_meta(full_path)
            _scan_directory(full_path)
        } else {
            if strings.has_suffix(entry.name, ".meta") do continue
            _ensure_meta(full_path)
        }
    }
}

_ensure_meta :: proc(asset_path: string) {
    meta_path := strings.concatenate({asset_path, ".meta"})
    defer delete(meta_path)

    if guid, ok := _read_meta(meta_path); ok {
        _register_asset(asset_path, guid)
    } else {
        guid := _generate_guid()
        _write_meta(meta_path, guid)
        _register_asset(asset_path, guid)
    }

    asset_pipeline_ensure_import_meta(asset_path)
}

_register_asset :: proc(path: string, guid: uuid.Identifier) {
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

_cleanup_orphaned_metas :: proc(dir_path: string) {
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
            _cleanup_orphaned_metas(full_path)
            continue
        }

        if !strings.has_suffix(entry.name, ".meta") do continue

        asset_name := strings.trim_suffix(full_path, ".meta")
        if !os.exists(asset_name) {
            os.remove(full_path)
            fmt.printf("[AssetDB] Removed orphaned meta: %s\n", full_path)
        }
    }
}

_generate_guid :: proc() -> uuid.Identifier {
    return uuid.generate_v4()
}
