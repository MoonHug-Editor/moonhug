package inspector

import "core:c"
import "core:fmt"
import "base:runtime"
import strings "core:strings"
import im "../../../external/odin-imgui"

is_enum_type :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	_, is_enum := ti.variant.(runtime.Type_Info_Enum)
	return is_enum
}

draw_inspector_enum :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring) {
	ti := runtime.type_info_base(type_info_of(field_tid))

	info, ok := ti.variant.(runtime.Type_Info_Enum)
	if !ok {
		im.TextColored(im.Vec4{1, 0, 0, 1}, "Not an enum type")
		return
	}

	names := make([dynamic]cstring, context.temp_allocator)
	for name in info.names {
		append(&names, strings.clone_to_cstring(name, context.temp_allocator))
	}

	current_index: c.int = 0
	current_val := _read_enum_value(field_ptr, info.base)
	for val, i in info.values {
		if val == current_val {
			current_index = c.int(i)
			break
		}
	}

	im.AlignTextToFramePadding()
	im.Text(label)
	im.SameLine(im.GetContentRegionAvail().x - 150)
	im.SetNextItemWidth(150)

	uid := fmt.tprintf("##%s", label)
	if im.ComboChar(strings.clone_to_cstring(uid, context.temp_allocator), &current_index, ([^]cstring)(raw_data(names[:])), c.int(len(names))) {
		_write_enum_value(field_ptr, info.base, info.values[current_index])
		mark_inspector_changed()
	}
	draw_clipboard_row_popup(field_ptr, field_tid)
}

@(private)
_read_enum_value :: proc(ptr: rawptr, base: ^runtime.Type_Info) -> runtime.Type_Info_Enum_Value {
	switch base.size {
	case 1: return runtime.Type_Info_Enum_Value((cast(^i8)ptr)^)
	case 2: return runtime.Type_Info_Enum_Value((cast(^i16)ptr)^)
	case 4: return runtime.Type_Info_Enum_Value((cast(^i32)ptr)^)
	case 8: return runtime.Type_Info_Enum_Value((cast(^i64)ptr)^)
	}
	return 0
}

@(private)
_write_enum_value :: proc(ptr: rawptr, base: ^runtime.Type_Info, val: runtime.Type_Info_Enum_Value) {
	switch base.size {
	case 1: (cast(^i8)ptr)^ = i8(val)
	case 2: (cast(^i16)ptr)^ = i16(val)
	case 4: (cast(^i32)ptr)^ = i32(val)
	case 8: (cast(^i64)ptr)^ = i64(val)
	}
}
