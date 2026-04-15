package serialization

import "core:reflect"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:io"
import "core:mem"
import "base:runtime"
import engine ".."

asset_guid_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	guid := (cast(^engine.Asset_GUID)v.data)^
	s := uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
	if err := json.marshal_to_writer(w, s, opt); err != nil do return err
	return nil
}

asset_guid_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, parse_err := json.parse_value(p)
	if parse_err != nil do return parse_err
	defer json.destroy_value(val)
	s, ok := val.(json.String)
	if !ok do return json.Unmarshal_Data_Error.Invalid_Data
	id, read_err := uuid.read(s)
	if read_err != nil do return json.Unmarshal_Data_Error.Invalid_Data
	(cast(^engine.Asset_GUID)v.data)^ = engine.Asset_GUID(id)
	return nil
}

union_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    tid := reflect.union_variant_typeid(v)
    if tid == nil {
        _, e := io.write_string(w, "null")
        if e != .None do return .Unsupported_Type
        return nil
    }

    guid := engine.get_guid_by_typeid(tid)
    guid_str := uuid.to_string(guid, context.temp_allocator)

    _, e := io.write_string(w, "{\"__type_guid\":")
    if e != .None do return .Unsupported_Type

    if err := json.marshal_to_writer(w, guid_str, opt); err != nil do return err

    variant_any := any{v.data, tid}
    variant_bytes, marshal_err := json.marshal(variant_any, opt^, context.temp_allocator)
    if marshal_err != nil do return marshal_err

    if len(variant_bytes) > 1 && variant_bytes[0] == '{' {
        stripped := variant_bytes[1:]
        if len(stripped) > 0 && stripped[0] != '}' {
            _, e = io.write_string(w, ",")
            if e != .None do return .Unsupported_Type
        }
        _, e = io.write(w, stripped)
        if e != .None do return .Unsupported_Type
    } else {
        _, e = io.write_string(w, "}")
        if e != .None do return .Unsupported_Type
    }

    return nil
}

union_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
    obj_val, parse_err := json.parse_value(p)
    if parse_err != nil do return parse_err
    defer json.destroy_value(obj_val)

    root, ok := obj_val.(json.Object)
    if !ok do return json.Unmarshal_Data_Error.Invalid_Data

    type_val, has_type := root["__type_guid"]
    if !has_type do return json.Unmarshal_Data_Error.Invalid_Data

    guid_str, guid_ok := type_val.(json.String)
    if !guid_ok do return json.Unmarshal_Data_Error.Invalid_Data

    guid, guid_err := uuid.read(guid_str)
    if guid_err != nil do return json.Unmarshal_Data_Error.Invalid_Data

    tid := engine.get_typeid_by_guid(guid)
    if tid == nil do return json.Unmarshal_Data_Error.Invalid_Data

    heap := runtime.default_allocator()

    data_bytes, marshal_err := json.marshal(root, allocator = context.temp_allocator)
    if marshal_err != nil do return json.Unmarshal_Data_Error.Invalid_Data

    ti := type_info_of(tid)
    variant_ptr, alloc_err := mem.alloc(ti.size, ti.align, heap)
    if alloc_err != nil do return json.Unmarshal_Data_Error.Invalid_Data
    mem.zero(variant_ptr, ti.size)

    ptr_tid, ptr_tid_ok := engine.get_pointer_typeid_by_typeid(tid)
    if !ptr_tid_ok do return json.Unmarshal_Data_Error.Invalid_Data

    if uerr := json.unmarshal_any(data_bytes, any{&variant_ptr, ptr_tid}, allocator = heap); uerr != nil {
        mem.free(variant_ptr, heap)
        return uerr
    }

    mem.copy(v.data, variant_ptr, ti.size)
    reflect.set_union_variant_typeid(v, tid)
    mem.free(variant_ptr, heap)

    return nil
}
