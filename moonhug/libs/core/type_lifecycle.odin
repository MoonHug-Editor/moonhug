package core

// Per-type lifecycle procs (plugins/engine/docs/Components.md, "Lifecycle procs"): a
// @(typ_guid) type declares them by name in its own file, and the generated
// registration (type_guid_gen) puts them in these tables by TypeKey.
//
// - reset_T:       cleanup_T first when the type has one, then the defaults,
//                  so a reset on a live value frees what it owned. A new
//                  instance gets it, a value loaded from data gets it under
//                  the data (unmarshal_over_reset), and the inspector's Reset
//                  runs it on a live value.
// - cleanup_T:     frees what a value owns and leaves it zeroed. Runs when a
//                  component is destroyed, when a union variant goes, when a
//                  tween node is destroyed.
// - on_validate_T: after an inspector edit and after a value is loaded from
//                  data, to keep the value consistent (a zero that means
//                  "default" becomes the default here).
//
// @(comp_on_destroy) stays a component's (plugins/engine/components.odin): it
// is about leaving a world, not about the value.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

type_reset_procs:       [TypeKey]proc(rawptr)
// Registers the proc that frees one field type when the struct holding it is
// destroyed.
//
// `type` is the field type ("string", Curve) and the proc takes a pointer to
// the field. `priority` decides which of two procs for one type is used. This
// is how heap-owning fields inside components are released without
// per-component code.
@(extension_point={attribute="cleanup", target="proc", fields="type priority"})
type_cleanup_procs:     [TypeKey]proc(rawptr)
type_on_validate_procs: [TypeKey]proc(rawptr)

// A string field owns its bytes.
@(cleanup={type=string, priority=0})
type_cleanup_string_field :: proc(s: ^string) {
	delete(s^)
}

type_register_reset :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_reset_procs[key] = fn
}

type_register_cleanup :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_cleanup_procs[key] = fn
}

type_register_on_validate :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_on_validate_procs[key] = fn
}

type_has_reset :: proc(key: TypeKey) -> bool {
	return type_reset_procs[key] != nil
}

type_has_cleanup :: proc(key: TypeKey) -> bool {
	return type_cleanup_procs[key] != nil
}

type_reset :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_reset_procs[key]; fn != nil do fn(ptr)
}

type_cleanup :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_cleanup_procs[key]; fn != nil do fn(ptr)
}

type_cleanup_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_cleanup(key, ptr)
}

type_on_validate :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_on_validate_procs[key]; fn != nil do fn(ptr)
}

type_on_validate_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_on_validate(key, ptr)
}

// The Serialization project setting (plugins/engine/docs/Components.md,
// "Missing fields and reset defaults"). It lives in core because every typed load
// reads it, and core cannot import the engine.
Serialization_Settings :: struct {
	// On: a top-level field a scene, prefab, asset, import settings or union
	// variant file does not name loads as the type's reset_T default. The cost
	// is a reset and a cleanup on a scratch copy for every loaded value whose
	// type has a reset_T. Off: a field missing from a file loads as zero, so a
	// field added to a type after a file was saved must tolerate zero or be
	// migrated by hand.
	load_defaults_for_missing_fields: bool `decor:help(text="On: a field a file does not name loads as the type's reset default, not zero. Costs a reset and a cleanup on a scratch copy per loaded component or asset. Off: a missing field loads as zero.")`,
}

@(project_settings={name="Serialization"})
serialization_settings := Serialization_Settings{load_defaults_for_missing_fields = true}

// Loads ProjectSettings/serialization.json before anything is loaded from
// data. A missing file keeps the initializer above.
@(phase={key=SerializationInit, order=-300})
_serialization_settings_load :: proc() {
	project_settings_load("Serialization", &serialization_settings)
}

// Unmarshals `data`, one JSON object, over the zeroed T at `ptr` (`tid` is T).
// A top-level field the object names comes from the data. Every other field
// keeps T's reset default, so a field added to T after the data was saved
// loads as its reset value, not zero. Every load of a typed value from data
// goes through here or through the two variants below: scene and prefab
// components, assets, import settings, union variants. A T with no reset_T,
// or serialization_settings.load_defaults_for_missing_fields off, gets a plain
// unmarshal.
//
// This variant starts from bytes only, so it parses `data` once to learn which
// keys it names. A caller that already holds the parsed object passes it to
// unmarshal_over_reset_object, and a caller that holds a json.Value passes it
// to unmarshal_value_over_reset.
unmarshal_over_reset :: proc(
	data: []byte,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	if !_needs_reset_defaults(tid) do return _unmarshal_plain(data, ptr, tid, spec, allocator)
	root, perr := json.parse(data, spec, true, context.temp_allocator)
	obj, is_obj := root.(json.Object)
	if perr != nil || !is_obj {
		// Not an object: the unmarshal reports what is wrong with it.
		return _unmarshal_plain(data, ptr, tid, spec, allocator)
	}
	return unmarshal_over_reset_object(data, obj, ptr, tid, spec, allocator)
}

// unmarshal_over_reset for a caller that holds `obj`, the parsed form of
// `data`: the key set comes from `obj`, so `data` is not parsed a second time.
//
// reset_T runs on a scratch T, never on `ptr`: a reset may allocate, and the
// unmarshal would allocate over it. The fields the data lacks then move from
// the scratch into `ptr`, and cleanup_T frees what the scratch still holds
// (the defaults of the fields the data supplied). The scratch and the moved
// defaults are on `allocator`, the same as the unmarshaled fields.
unmarshal_over_reset_object :: proc(
	data: []byte,
	obj: json.Object,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	if !_needs_reset_defaults(tid) do return _unmarshal_plain(data, ptr, tid, spec, allocator)
	key, _ := get_type_key_by_typeid(tid)
	info := runtime.type_info_base(type_info_of(tid)).variant.(runtime.Type_Info_Struct)

	context.allocator = allocator
	ti := type_info_of(tid)
	scratch, aerr := mem.alloc(ti.size, ti.align)
	fmt.assertf(aerr == nil, "out of memory for a %v scratch", tid)
	defer mem.free(scratch)
	type_reset(key, scratch)
	defer type_cleanup(key, scratch)

	if err := _unmarshal_plain(data, ptr, tid, spec, allocator); err != nil do return err
	_take_absent_fields(ptr, scratch, info, obj)
	return nil
}

// unmarshal_over_reset for a caller that holds a json.Value: marshals `v` once
// for the unmarshal and takes the key set from `v` itself.
unmarshal_value_over_reset :: proc(
	v: json.Value,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	data, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return json.Unmarshal_Data_Error.Invalid_Data
	obj, is_obj := v.(json.Object)
	if !is_obj {
		// Not an object: the unmarshal reports what is wrong with it.
		return _unmarshal_plain(data, ptr, tid, spec, allocator)
	}
	return unmarshal_over_reset_object(data, obj, ptr, tid, spec, allocator)
}

// True when a load of `tid` keeps reset defaults for absent fields: the
// setting is on, and T is a struct with a reset_T.
@(private = "file")
_needs_reset_defaults :: proc(tid: typeid) -> bool {
	if !serialization_settings.load_defaults_for_missing_fields do return false
	key, keyed := get_type_key_by_typeid(tid)
	if !keyed || !type_has_reset(key) do return false
	_, is_struct := runtime.type_info_base(type_info_of(tid)).variant.(runtime.Type_Info_Struct)
	return is_struct
}

@(private = "file")
_unmarshal_plain :: proc(
	data: []byte,
	ptr: rawptr,
	tid: typeid,
	spec: json.Specification,
	allocator: runtime.Allocator,
) -> json.Unmarshal_Error {
	ptr_tid, ptr_ok := get_pointer_typeid_by_typeid(tid)
	fmt.assertf(ptr_ok, "%v has no pointer type (register_pointer_type)", tid)
	pp := ptr
	return json.unmarshal_any(data, any{&pp, ptr_tid}, spec, allocator)
}

// Swaps every field of `dst` the JSON object does not name with the same field
// of `src`. The names follow json.unmarshal: the `json` tag's name, else the
// field name, and the fields of a `using _:` field sit in the parent object.
// A `json:"-"` field is never in the data, so it always takes `src`'s value.
@(private = "file")
_take_absent_fields :: proc(dst, src: rawptr, info: runtime.Type_Info_Struct, obj: json.Object) {
	for i in 0 ..< int(info.field_count) {
		off := info.offsets[i]
		ftype := info.types[i]
		name := info.names[i]
		if info.usings[i] && name == "_" {
			if sub, ok := runtime.type_info_base(ftype).variant.(runtime.Type_Info_Struct); ok {
				_take_absent_fields(rawptr(uintptr(dst) + off), rawptr(uintptr(src) + off), sub, obj)
				continue
			}
		}
		json_name := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
		if comma := strings.index_byte(json_name, ','); comma >= 0 do json_name = json_name[:comma]
		if json_name != "-" {
			if json_name == "" do json_name = name
			if json_name in obj do continue
		}
		a := ([^]byte)(rawptr(uintptr(dst) + off))
		b := ([^]byte)(rawptr(uintptr(src) + off))
		for j in 0 ..< ftype.size {
			a[j], b[j] = b[j], a[j]
		}
	}
}
