package engine

// The added_components and added_objects records of an instance carry their
// payload as JSON text (`json: string`), which the plain writer escapes into
// one long string. These hooks write the payload inline, as the object it is,
// and read either form, so a file shows an added component or subtree the
// way it shows any other, and the records keep their string for every other
// use (the apply into a baked prefab, undo payloads, snapshots).

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:io"
import "core:strings"

@(phase={key=SerializationInit, order=1})
nested_records_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(Added_Component, _added_component_marshal)
	json.register_user_unmarshaler(Added_Component, _added_component_unmarshal)
	json.register_user_marshaler(Added_Object, _added_object_marshal)
	json.register_user_unmarshaler(Added_Object, _added_object_unmarshal)
}

// The records as the file holds them: the payload parsed, so it writes inline.
@(private = "file")
_Added_Component_File :: struct {
	owner:     PPtr,
	local_id:  Local_ID,
	type_guid: string,
	json:      json.Value,
}

@(private = "file")
_Added_Object_File :: struct {
	parent:   PPtr,
	local_id: Local_ID,
	json:     json.Value,
}

@(private = "file")
_added_component_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	ac := cast(^Added_Component)v.data
	file := _Added_Component_File{owner = ac.owner, local_id = ac.local_id, type_guid = ac.type_guid, json = _payload_value(ac.json)}
	return json.marshal_to_writer(w, file, opt)
}

@(private = "file")
_added_object_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	ao := cast(^Added_Object)v.data
	file := _Added_Object_File{parent = ao.parent, local_id = ao.local_id, json = _payload_value(ao.json)}
	return json.marshal_to_writer(w, file, opt)
}

// The payload parsed on the temp allocator. Text that is not JSON writes as
// the string it is.
@(private = "file")
_payload_value :: proc(text: string) -> json.Value {
	val, err := json.parse(transmute([]byte)text, .JSON, true, context.temp_allocator)
	if err != nil do return json.String(text)
	return val
}

@(private = "file")
_added_component_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, perr := json.parse_value(p)
	if perr != nil do return perr
	defer json.destroy_value(val, p.allocator)
	obj, is_obj := val.(json.Object)
	if !is_obj do return json.Unmarshal_Data_Error.Invalid_Data
	ac := cast(^Added_Component)v.data
	ac.owner = _pptr_of(obj["owner"])
	ac.local_id = _lid_of(obj["local_id"])
	if s, ok := obj["type_guid"].(json.String); ok do ac.type_guid = strings.clone(s, p.allocator)
	ac.json = _payload_text(obj["json"], p.allocator)
	return nil
}

@(private = "file")
_added_object_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, perr := json.parse_value(p)
	if perr != nil do return perr
	defer json.destroy_value(val, p.allocator)
	obj, is_obj := val.(json.Object)
	if !is_obj do return json.Unmarshal_Data_Error.Invalid_Data
	ao := cast(^Added_Object)v.data
	ao.parent = _pptr_of(obj["parent"])
	ao.local_id = _lid_of(obj["local_id"])
	ao.json = _payload_text(obj["json"], p.allocator)
	return nil
}

// The payload as the record keeps it: a string as written, an object or an
// array marshaled back to compact text.
@(private = "file")
_payload_text :: proc(v: json.Value, allocator: runtime.Allocator) -> string {
	#partial switch payload in v {
	case json.String:
		return strings.clone(payload, allocator)
	case json.Object, json.Array:
		bytes, err := json.marshal(v, {spec = .JSON}, allocator)
		if err == nil do return string(bytes)
	}
	return ""
}

@(private = "file")
_lid_of :: proc(v: json.Value) -> Local_ID {
	#partial switch n in v {
	case json.Integer: return Local_ID(n)
	case json.Float:   return Local_ID(n)
	}
	return 0
}

@(private = "file")
_pptr_of :: proc(v: json.Value) -> (out: PPtr) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	out.local_id = _lid_of(obj["local_id"])
	if s, ok := obj["guid"].(json.String); ok {
		if id, err := uuid.read(s); err == nil do out.guid = Asset_GUID(id)
	}
	return
}
