package inspector

import "core:c"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "base:runtime"
import strings "core:strings"
import im "../../../external/odin-imgui"

draw_inspector_union :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring) {
	ti := runtime.type_info_base(type_info_of(field_tid))

	if info, ok := ti.variant.(runtime.Type_Info_Union); ok {
		draw_union_field(field_ptr, info, label, field_tid)
	} else {
		im.TextColored(im.Vec4{1, 0, 0, 1}, "Not a union type")
	}
}

is_union_type :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	_, is_union := ti.variant.(runtime.Type_Info_Union)
	return is_union
}

draw_union_field :: proc(ptr: rawptr, info: runtime.Type_Info_Union, label: cstring, field_tid: typeid) {
	tag_ptr := rawptr(uintptr(ptr) + uintptr(info.tag_offset))
	current_tag := (^i64)(tag_ptr)^

	is_no_nil := info.no_nil

	variant_names := make([dynamic]cstring, context.temp_allocator)
	if !is_no_nil {
		append(&variant_names, "None")
	}
	for variant in info.variants {
		name := fmt.tprintf("%v", variant)
		append(&variant_names, strings.clone_to_cstring(name, context.temp_allocator))
	}

	has_content := current_tag >= 0 && current_tag < i64(len(info.variants))

	tree_open := false
	if has_content {
		tree_open = im.TreeNodeEx(label, {.DefaultOpen})
	} else {
		im.AlignTextToFramePadding()
		im.Text(label)
	}
	draw_clipboard_row_popup(ptr, field_tid)

	im.SameLine(im.GetContentRegionAvail().x - 150)
	im.SetNextItemWidth(150)

	selected: c.int
	if is_no_nil {
		selected = c.int(current_tag)
	} else {
		selected = c.int(current_tag) + 1
	}

	if im.ComboChar("##type", &selected, ([^]cstring)(raw_data(variant_names[:])), c.int(len(variant_names))) {
		new_tag: i64
		if is_no_nil {
			new_tag = i64(selected)
		} else {
			new_tag = i64(selected - 1)
		}

		if new_tag >= 0 && new_tag < i64(len(info.variants)) {
			(^i64)(tag_ptr)^ = new_tag
			mem.zero(ptr, int(info.tag_offset))
		} else {
			(^i64)(tag_ptr)^ = -1
			mem.zero(ptr, int(info.tag_offset))
		}
	}

	if has_content && tree_open {
		variant_ti := info.variants[current_tag]
		variant_any := any{ptr, variant_ti.id}
		draw_inspector(variant_any)
		im.TreePop()
	}
}
