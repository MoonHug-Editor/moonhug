package engine

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "../engine/json"
import "core:encoding/uuid"

AssetDB :: struct {
    guid_to_path: map[uuid.Identifier]string,
    path_to_guid: map[string]uuid.Identifier,
    root_path:    string,
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
    delete(asset_db.root_path)
}

_free_maps :: proc() {
    for _, v in asset_db.guid_to_path {
        delete(v)
    }
    delete(asset_db.guid_to_path)
    delete(asset_db.path_to_guid)
}

asset_db_refresh :: proc() {
    _free_maps()
    asset_db.guid_to_path = make(map[uuid.Identifier]string)
    asset_db.path_to_guid = make(map[string]uuid.Identifier)

    _scan_directory(asset_db.root_path)
    _cleanup_orphaned_metas(asset_db.root_path)

    fmt.printf("[AssetDB] Refreshed: %d assets indexed\n", len(asset_db.guid_to_path))
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
