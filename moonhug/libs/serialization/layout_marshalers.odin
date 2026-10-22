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

register_layout_marshalers :: proc() {
	json.register_user_marshaler([2]f32, array_one_line_marshal)
	json.register_user_marshaler([3]f32, array_one_line_marshal)
	json.register_user_marshaler([4]f32, array_one_line_marshal)
	json.register_user_marshaler([2]i32, array_one_line_marshal)
	json.register_user_marshaler(core.PPtr, struct_one_line_marshal)
	json.register_user_marshaler(core.Ref, struct_one_line_marshal)
	json.register_user_marshaler(core.Ref_Local, struct_one_line_marshal)
	json.register_user_marshaler(core.Owned, struct_one_line_marshal)
}

// A fixed array on one line. Each element goes through the writer, so an
// element type with a marshaler of its own keeps it.
array_one_line_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	info := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Array)
	io.write_byte(w, '[') or_return
	for i in 0 ..< info.count {
		if i > 0 do _separator(w, opt) or_return
		elem := any{rawptr(uintptr(v.data) + uintptr(i * info.elem_size)), info.elem.id}
		json.marshal_to_writer(w, elem, opt) or_return
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
		json.marshal_to_writer(w, name, opt) or_return
		io.write_string(w, opt.pretty ? ": " : ":") or_return
		field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
		json.marshal_to_writer(w, field, opt) or_return
	}
	io.write_byte(w, '}') or_return
	return nil
}

@(private = "file")
_separator :: proc(w: io.Writer, opt: ^json.Marshal_Options) -> io.Error {
	_, err := io.write_string(w, opt.pretty ? ", " : ",")
	return err
}
