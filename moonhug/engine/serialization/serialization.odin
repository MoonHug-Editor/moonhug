package serialization

import "core:fmt"
import "core:reflect"
import "core:os"
import "core:encoding/json"
import "core:encoding/uuid"
import strings "core:strings"
import engine ".."
import "../log"

TYPE_GUID_KEY :: "__type_guid"

BeforeSerializeProc :: proc(ptr: rawptr, tid: typeid, is_cleanup: bool)
AfterDeserializeProc :: proc(ptr: rawptr, tid: typeid)

mapBeforeSerialize: map[typeid]BeforeSerializeProc
mapAfterDeserialize: map[typeid]AfterDeserializeProc

init :: proc() {
	mapBeforeSerialize = make(map[typeid]BeforeSerializeProc)
	mapAfterDeserialize = make(map[typeid]AfterDeserializeProc)
	init_serialization_callbacks()
}

load_from_file :: proc(filepath: string) -> (file_data: any, ok: bool) {
    // Validate filepath
    if filepath == "" || len(filepath) < 5 {
        log.error(fmt.tprintf("Invalid filepath: %s", filepath))
        return any{}, false
    }

    // Read file
    data, read_ok := os.read_entire_file(filepath, context.allocator)
    if read_ok != nil {
        log.error(fmt.tprintf("Failed to read file: %s", filepath))
        return any{}, false
    }
    defer delete(data)

    // Parse JSON
    json_data, err := json.parse(data)
    if err != nil {
        log.error(fmt.tprintf("Failed to parse JSON: %v", err))
        return any{}, false
    }
    defer json.destroy_value(json_data)

    // Extract root object
    root, ok_root := json_data.(json.Object)
    if !ok_root {
        log.error("JSON root is not an object")
        return any{}, false
    }

    // Get __typ_guid from root (inside object, no "data" wrapper)
    guid_value, ok_guid := root[TYPE_GUID_KEY]
    if !ok_guid {
        log.error("Missing __typ_guid field")
        return any{}, false
    }

    guid_str, ok_guid_str := guid_value.(json.String)
    if !ok_guid_str {
        log.error("__typ_guid is not a string")
        return any{}, false
    }

    guid, guid_parse_err := uuid.read(guid_str)
    if guid_parse_err != nil {
        log.error(fmt.tprintf("Invalid UUID in __type_guid: %s", guid_str))
        return any{}, false
    }

    instance := engine.create_instance_by_guid(guid)
    pointer_typeid := engine.get_pointer_typeid_by_typeid(instance.id)
    temp_ptr := instance.data
    target := any{ &temp_ptr, pointer_typeid }
    unmarshal_err:=json.unmarshal_any(data, target, json.DEFAULT_SPECIFICATION, context.allocator)
    if unmarshal_err != nil {
        log.error(fmt.tprintf("Failed to unmarshal JSON: %v", unmarshal_err))
        return any{}, false
    }

    result := instance
    if cb, ok := mapAfterDeserialize[result.id]; ok {
        cb(result.data, result.id)
    }
    log.info(fmt.tprintf("Loaded from %s", filepath))
    return result, true
}

// write_asset_to_path writes a default asset (guid + marshaled data) to file_path. Used by Create Asset menu.
write_asset_to_path :: proc(file_path: string, guid: uuid.Identifier, data: any) -> bool {
    if file_path == "" || len(file_path) < 5 {
        log.error("write_asset_to_path: invalid file path")
        return false
    }
    if cb, ok := mapBeforeSerialize[data.id]; ok {
        cb(data.data, data.id, false)
    }
    opts := json.Marshal_Options{
        spec    = .JSON,
        pretty  = true,
        use_spaces = true,
        spaces  = 2,
    }
    data_bytes, marshal_err := json.marshal(data, opts)
    if marshal_err != nil {
        log.error(fmt.tprintf("write_asset_to_path: JSON marshal failed: %v", marshal_err))
        return false
    }
    defer delete(data_bytes)
    if cb, ok_cb := mapBeforeSerialize[data.id]; ok_cb {
        cb(data.data, data.id, true)
    }
    guid_str := uuid.to_string(guid)
    defer delete(guid_str)
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, "{\n  \"")
    strings.write_string(&builder, TYPE_GUID_KEY)
    strings.write_string(&builder, "\": \"")
    strings.write_string(&builder, guid_str)
    strings.write_string(&builder, "\",\n  ")
    strings.write_bytes(&builder, data_bytes[4:])
    full_json := strings.to_string(builder)
    if write_err := os.write_entire_file(file_path, transmute([]byte)full_json); write_err != nil {
        log.error(fmt.tprintf("write_asset_to_path: failed to write %s", file_path))
        return false
    }
    log.info(fmt.tprintf("Created asset: %s", file_path))
    return true
}

save_to_file :: proc(filepath: string, file_data: any) -> bool {
    if filepath == "" || len(filepath) < 5 {
        log.error(fmt.tprintf("Invalid filepath: %s", filepath))
        return false
    }

    tid := file_data.id
    if cb, ok := mapBeforeSerialize[tid]; ok {
        cb(file_data.data, tid, false)
    }

    guid := engine.get_guid_by_typeid(tid)

    opts := json.Marshal_Options{
        spec    = .JSON,
        pretty  = true,
        use_spaces = true,
        spaces  = 2,
    }
    data_bytes, marshal_err := json.marshal(file_data, opts)
    if marshal_err != nil {
        log.error(fmt.tprintf("JSON marshal failed: %v", marshal_err))
        return false
    }
    defer delete(data_bytes)
    if cb, ok := mapBeforeSerialize[tid]; ok {
        cb(file_data.data, tid, true)
    }

    guid_str := uuid.to_string(guid)
    defer delete(guid_str)
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, "{\n  \"")
    strings.write_string(&builder, TYPE_GUID_KEY)
    strings.write_string(&builder, "\": \"")
    strings.write_string(&builder, guid_str)
    strings.write_string(&builder, "\",\n  ")
    strings.write_bytes(&builder, data_bytes[4:])

    full_json := strings.to_string(builder)

    if write_err := os.write_entire_file(filepath, transmute([]byte)full_json); write_err != nil {
        log.error(fmt.tprintf("Failed to write file: %s", filepath))
        return false
    }

    log.info(fmt.tprintf("Saved successfully to %s", filepath))
    return true
}
