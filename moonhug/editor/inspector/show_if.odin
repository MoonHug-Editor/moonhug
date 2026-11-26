package inspector

// The `show_if` field tag (field_tags.odin): a row that shows only while
// another field of the same struct holds one of the listed values.

import "core:fmt"
import "core:reflect"
import "core:strings"

// Whether the field with `tag` shows on `owner`, a struct of type `tid`. A
// field with no `show_if` always shows.
field_show_if :: proc(tag: reflect.Struct_Tag, owner: rawptr, tid: typeid) -> bool {
	rule, has := tag_value(tag, TAG_SHOW_IF)
	if !has do return true
	eq := strings.index_byte(rule, '=')
	if eq <= 0 do fmt.panicf("show_if:%q on a field of %v: it is written \"field=Value,Value\"", rule, tid)
	name := strings.trim_space(rule[:eq])
	other := reflect.struct_field_by_name(tid, name)
	if other.type == nil do fmt.panicf("show_if:%q on a field of %v: %v has no field %q", rule, tid, tid, name)
	value := any{rawptr(uintptr(owner) + other.offset), other.type.id}

	// The other field's value as the tag spells it.
	text: string
	#partial switch info in reflect.type_info_base(other.type).variant {
	case reflect.Type_Info_Enum:
		text = reflect.enum_string(value)
	case reflect.Type_Info_Boolean:
		b, _ := reflect.as_bool(value)
		text = "true" if b else "false"
	case reflect.Type_Info_Integer:
		n, _ := reflect.as_i64(value)
		text = fmt.tprintf("%d", n)
	case:
		fmt.panicf("show_if:%q on a field of %v: %q is a %v, it reads an enum, a bool or an integer", rule, tid, name, other.type.id)
	}

	rest := rule[eq + 1:]
	for want in strings.split_iterator(&rest, ",") {
		if strings.trim_space(want) == text do return true
	}
	return false
}
