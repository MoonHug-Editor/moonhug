package serialization

// Literal types a union variant can be: a type the language spells, such as
// `f32`, `bool` or `[3]f32`, with no declaration to carry a @(typ_guid). A
// union saves such a variant tagged with its text, which the language fixes,
// so it is as stable as a guid.
//
// register_union_type fills the table with the literal variants of every
// union it registers.

import "base:runtime"
import "core:strings"

@(private) _literal_by_text: map[string]typeid
@(private) _text_by_literal: map[typeid]string

@(init)
_literal_types_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	_literal_by_text = make(map[string]typeid, alloc)
	_text_by_literal = make(map[typeid]string, alloc)
}

// The text a literal type is saved by: `f32`, `int`, `bool`, `string`,
// `[3]f32`. False for a declared type, which has a name of its own and is
// saved by its guid, and for a kind of type no union variant needs yet.
literal_type_text :: proc(T: typeid) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	if !_write_literal(&b, type_info_of(T)) do return "", false
	return strings.to_string(b), true
}

@(private)
_write_literal :: proc(b: ^strings.Builder, ti: ^runtime.Type_Info) -> bool {
	#partial switch info in ti.variant {
	case runtime.Type_Info_Integer:
		switch ti.id {
		case int:     strings.write_string(b, "int")
		case uint:    strings.write_string(b, "uint")
		case uintptr: strings.write_string(b, "uintptr")
		case:
			if info.endianness != .Platform do return false
			strings.write_byte(b, 'i' if info.signed else 'u')
			strings.write_int(b, 8 * ti.size)
		}
	case runtime.Type_Info_Float:
		if info.endianness != .Platform do return false
		strings.write_byte(b, 'f')
		strings.write_int(b, 8 * ti.size)
	case runtime.Type_Info_Boolean:
		if ti.id != bool do return false
		strings.write_string(b, "bool")
	case runtime.Type_Info_Rune:
		strings.write_string(b, "rune")
	case runtime.Type_Info_String:
		if ti.id != string do return false
		strings.write_string(b, "string")
	case runtime.Type_Info_Array:
		strings.write_byte(b, '[')
		strings.write_int(b, info.count)
		strings.write_byte(b, ']')
		return _write_literal(b, info.elem)
	case:
		return false
	}
	return true
}

// Records that `text` is literal type `T`, for loading it back.
literal_type_register :: proc(text: string, T: typeid) {
	if _, has := _text_by_literal[T]; has do return
	context.allocator = runtime.default_allocator()
	owned := strings.clone(text)
	_literal_by_text[owned] = T
	_text_by_literal[T] = owned
}

// The literal type saved as `text`, false when no registered union has it.
literal_type_of :: proc(text: string) -> (typeid, bool) {
	T, ok := _literal_by_text[text]
	return T, ok
}

// The text literal type `T` is saved by, false when no registered union has it.
literal_type_saved_text :: proc(T: typeid) -> (string, bool) {
	text, ok := _text_by_literal[T]
	return text, ok
}

