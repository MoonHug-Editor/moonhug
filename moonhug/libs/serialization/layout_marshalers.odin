package serialization

// One-line forms for the small values a scene is made of: a vector or a
// color is `[1.0, 2.0, 3.0]`, a reference is `{"local_id": 1, "guid": "..."}`.
// A moved object then diffs as one changed line, and a reference reads as
// one. The text is the JSON the plain writer produces, on one line, so the
// reader is unchanged and a file written before this loads the same.
//
// Registered on the SerializationInit phase after the marshaler maps exist
// (register_component_serializers).

import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:reflect"
import "core:strings"
import core "moonhug:libs/core"
import "moonhug:libs/slots"
import "moonhug:libs/time"

register_layout_marshalers :: proc() {
	json.register_user_marshaler(f32, float_fixed_marshal)
	json.register_user_marshaler(f64, float_fixed_marshal)
	json.register_user_marshaler([2]f32, array_one_line_marshal)
	json.register_user_marshaler([3]f32, array_one_line_marshal)
	json.register_user_marshaler([4]f32, array_one_line_marshal)
	json.register_user_marshaler([2]i32, array_one_line_marshal)
	json.register_user_marshaler(core.PPtr, pptr_marshal)
	json.register_user_unmarshaler(core.PPtr, pptr_unmarshal)
	json.register_user_marshaler(core.Ref, struct_one_line_marshal)
	json.register_user_marshaler(core.Ref_Local, struct_one_line_marshal)
	json.register_user_marshaler(core.Owned, struct_one_line_marshal)
	json.register_user_marshaler(time.Clock, clock_marshal)
	json.register_user_unmarshaler(time.Clock, clock_unmarshal)
	json.register_user_marshaler(slots.Slot, slot_marshal)
	json.register_user_unmarshaler(slots.Slot, slot_unmarshal)
}

// A float with fixed fraction digits, 8 for an f32 and 16 for an f64. Every
// asset file holds floats in this text (trailing zeros trimmed by
// core.json_canonicalize_floats), and an override compares a saved value to
// a live one after both went through it. The plain writer picks the shortest
// text that reads back the same, which is other text for the same value.
float_fixed_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	switch f in v {
	case f32: io.write_f32(w, f) or_return
	case f64: io.write_f64(w, f) or_return
	}
	return nil
}

// A fixed array on one line. Each element goes through the writer, so an
// element type with a marshaler of its own keeps it.
array_one_line_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	info := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Array)
	io.write_byte(w, '[') or_return
	for i in 0 ..< info.count {
		if i > 0 do _separator(w, opt) or_return
		elem := any{rawptr(uintptr(v.data) + uintptr(i * info.elem_size)), info.elem.id}
		json.marshal_to_writer(w, elem, opt^) or_return
	}
	io.write_byte(w, ']') or_return
	return nil
}

// A struct on one line, the fields in declaration order, named by the `json`
// tag when there is one, and left out when the tag is "-". The values go
// through the writer, so a nested reference stays on the line.
struct_one_line_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	info := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Struct)
	io.write_byte(w, '{') or_return
	written := 0
	for i in 0 ..< info.field_count {
		name := info.names[i]
		if tag, has := reflect.struct_tag_lookup(reflect.Struct_Tag(info.tags[i]), "json"); has {
			tag_name := tag
			if comma := strings.index_byte(tag_name, ','); comma >= 0 do tag_name = tag_name[:comma]
			if tag_name == "-" do continue
			if tag_name != "" do name = tag_name
		}
		if written > 0 do _separator(w, opt) or_return
		written += 1
		json.marshal_to_writer(w, name, opt^) or_return
		io.write_string(w, opt.pretty ? ": " : ":") or_return
		field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
		json.marshal_to_writer(w, field, opt^) or_return
	}
	io.write_byte(w, '}') or_return
	return nil
}

@(private = "file")
_separator :: proc(w: io.Writer, opt: ^json.Marshal_Options) -> io.Error {
	_, err := io.write_string(w, opt.pretty ? ", " : ",")
	return err
}

// time.Clock saves as its name. The enum is generated from what the installed
// packages add (Clock_Extra), so a clock's number changes when a package comes
// or goes, and its name does not.
clock_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	clock := (cast(^time.Clock)v.data)^
	name, _ := reflect.enum_name_from_value(clock)
	io.write_quoted_string(w, name)
	return nil
}

// Reads a clock by name. A number is accepted too, for values written before
// clocks saved by name. A name no installed package declares reads as Update.
clock_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, perr := json.parse_value(p)
	if perr != nil do return perr
	prev := context.allocator
	context.allocator = p.allocator
	defer {
		json.destroy_value(val)
		context.allocator = prev
	}
	out := cast(^time.Clock)v.data
	out^ = .Update
	#partial switch x in val {
	case json.String:
		if clock, ok := reflect.enum_from_name(time.Clock, string(x)); ok do out^ = clock
	case json.Integer:
		if x >= 0 && int(x) < len(time.Clock) do out^ = time.Clock(x)
	case json.Float:
		if x >= 0 && int(x) < len(time.Clock) do out^ = time.Clock(int(x))
	}
	return nil
}

// slots.Slot saves as the name of the entry it is connected to, an empty
// string when it is not connected. The number in memory is given out as names
// are first used, so it is not the same in every run.
slot_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	io.write_quoted_string(w, slots.name((cast(^slots.Slot)v.data)^))
	return nil
}

slot_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, perr := json.parse_value(p)
	if perr != nil do return perr
	prev := context.allocator
	context.allocator = p.allocator
	defer {
		json.destroy_value(val)
		context.allocator = prev
	}
	out := cast(^slots.Slot)v.data
	out^ = slots.INLINE
	if name, ok := val.(json.String); ok do out^ = slots.entry(string(name))
	return nil
}
