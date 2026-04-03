package engine

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:reflect"
import "core:encoding/uuid"

Factory :: proc() -> any
Guid_Type_Map :: map[uuid.Identifier]typeid
Type_Guid_Map :: map[typeid]uuid.Identifier
Type_PointerType_Map :: map[typeid]typeid
Guid_Factory_Map :: map[uuid.Identifier]Factory
Typeid_Factory_Map :: map[typeid]Factory
Guid_TypeMeta_Map :: map[uuid.Identifier]TypeMeta
Typeid_TypeMeta_Map :: map[typeid]TypeMeta

guid_to_type: Guid_Type_Map
typeid_to_guid: Type_Guid_Map
guid_to_factory: Guid_Factory_Map
typeid_to_factory: Typeid_Factory_Map
guid_to_typeMeta : Guid_TypeMeta_Map
typeid_to_typeMeta : Typeid_TypeMeta_Map
typeid_to_pointerType : Type_PointerType_Map

type_key_to_typeid_arr:      [TypeKey]typeid
type_key_to_guid_arr:        [TypeKey]uuid.Identifier
type_key_to_factory_arr:     [TypeKey]Factory
type_key_to_typeMeta_arr:    [TypeKey]TypeMeta
type_key_to_pointerType_arr: [TypeKey]typeid
typeid_to_type_key_map: map[typeid]TypeKey

_typeid_counter : u16

FieldInfo :: struct
{
    name: string,
    offset: uintptr,
    typeId: typeid,
}

TypeMeta :: struct
{
    guid: uuid.Identifier,
    typeId: typeid,
    typeU16 : u16,
    pointer_typeId: typeid,
    size: int,
    fields: [dynamic]FieldInfo,
}

typeid_to_u16 :: proc($T: typeid) -> u16 {
    @static id: u16 = max(u16)
    if id == max(u16) {
        id = _typeid_counter
        _typeid_counter += 1
    }
    return id
}

generate_type_info :: proc($T: typeid) -> TypeMeta {
    info := TypeMeta{
        typeId = T,
        typeU16 = typeid_to_u16(T),
        pointer_typeId = ^T,
        size = size_of(T),
        fields = [dynamic]FieldInfo{},
        }
    for field in reflect.struct_fields_zipped(T) {
        append(&info.fields, FieldInfo{
            name = field.name,
            offset = field.offset,
            typeId = field.type.id,
        })
    }
    return info;
}

register_type :: proc($T: typeid, guid: uuid.Identifier, factory: Factory = nil) {
    if T in typeid_to_guid {
        panic("Type '?' is already registered.")
    }
    if guid in guid_to_type {
        panic("GUID '?' is already used by another type.")
    }

    guid_to_type[guid] = T
    typeid_to_guid[T] = guid
    guid_to_factory[guid] = factory
    typeid_to_factory[T] = factory
    typeMeta := generate_type_info(T)
    typeid_to_typeMeta[T] = typeMeta
    guid_to_typeMeta[guid] = typeMeta
    typeid_to_pointerType[T] = ^T
}

register_pointer_type :: proc($T: typeid) {
	typeid_to_pointerType[T] = ^T
}

register_type_key :: proc($T: typeid, key: TypeKey) {
    type_key_to_typeid_arr[key]      = T
    type_key_to_guid_arr[key]        = typeid_to_guid[T]
    type_key_to_factory_arr[key]     = typeid_to_factory[T]
    type_key_to_typeMeta_arr[key]    = typeid_to_typeMeta[T]
    type_key_to_pointerType_arr[key] = typeid_to_pointerType[T]
    typeid_to_type_key_map[T]        = key
}

get_typeid_by_type_key :: proc(key: TypeKey) -> typeid {
    return type_key_to_typeid_arr[key]
}

get_guid_by_type_key :: proc(key: TypeKey) -> uuid.Identifier {
    return type_key_to_guid_arr[key]
}

get_factory_by_type_key :: proc(key: TypeKey) -> Factory {
    return type_key_to_factory_arr[key]
}

get_typeMeta_by_type_key :: proc(key: TypeKey) -> TypeMeta {
    return type_key_to_typeMeta_arr[key]
}

get_pointerType_by_type_key :: proc(key: TypeKey) -> typeid {
    return type_key_to_pointerType_arr[key]
}

get_type_key_by_typeid :: proc(T: typeid) -> (TypeKey, bool) {
    key, ok := typeid_to_type_key_map[T]
    return key, ok
}

create_instance_by_type_key :: proc(key: TypeKey) -> any {
    factory := type_key_to_factory_arr[key]
    if factory == nil {
        tid := type_key_to_typeid_arr[key]
        ti := type_info_of(tid)
        ptr, err := mem.alloc(ti.size, ti.align)
        if err != nil {
            panic(fmt.tprintf("Failed to allocate memory for type '%v'", tid))
        }
        mem.zero(ptr, ti.size)
        return any{ ptr, tid }
    }
    return factory()
}

create_instance_by_guid :: proc(guid: uuid.Identifier) -> any {
    factory := guid_to_factory[guid]
    if factory == nil {
        tid := get_typeid_by_guid(guid)
        ti := type_info_of(tid)
        ptr, err := mem.alloc(ti.size, ti.align)
        if err != nil {
            panic(fmt.tprintf("Failed to allocate memory for type '%v'", tid))
        }
        mem.zero(ptr, ti.size)
        return any{ ptr, tid }
    }
    return factory()
}

create_instance :: proc($T: typeid) -> T {
    if T not_in typeid_to_guid {
        panic(fmt.tprintf("Type '%v' is not registered with the type system"))
    }

    factory := typeid_to_factory[T]
    if factory == nil {
        panic("No factory found for type")
    }

    v := factory()
    if v == nil {
        panic(fmt.tprintf("Factory for type '%v' returned nil"))
    }

    if result, ok := v.(T); ok {
        return result
    }
    panic(fmt.tprintf("Factory for type '%v' returned incorrect type"))
}

get_guid_by_typeid :: proc(T: typeid) -> uuid.Identifier {
    if key, ok := typeid_to_type_key_map[T]; ok {
        return type_key_to_guid_arr[key]
    }
    if guid, ok := typeid_to_guid[T]; ok {
        return guid
    }
    panic(fmt.tprintf("Unknown GUID for T: %v", T))
}

get_typeid_by_guid :: proc(guid: uuid.Identifier) -> typeid {
    if T, ok := guid_to_type[guid]; ok {
        return T
    }
    panic(fmt.tprintf("Unknown GUID: %s", guid))
}

get_pointer_typeid_by_typeid :: proc(T: typeid) -> (result: typeid, ok: bool) {
    if key, key_ok := typeid_to_type_key_map[T]; key_ok {
        return type_key_to_pointerType_arr[key], true
    }
    if ptr_tid, map_ok := typeid_to_pointerType[T]; map_ok {
        return ptr_tid, true
    }
    return nil, false
}

