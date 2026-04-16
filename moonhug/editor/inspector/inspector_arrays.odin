package inspector

import "core:c"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "base:runtime"
import strings "core:strings"
import im "../../../external/odin-imgui"

// draw_inspector_array draws a dynamic or fixed array field. Called from the inspector when a field type is an array.
draw_inspector_array :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring) {
	ti := runtime.type_info_base(type_info_of(field_tid))

	if info, ok := ti.variant.(runtime.Type_Info_Dynamic_Array); ok {
		da := (^runtime.Raw_Dynamic_Array)(field_ptr)
		draw_dynamic_array(da, info.elem, field_ptr, field_tid, label)
	} else if info, ok := ti.variant.(runtime.Type_Info_Array); ok {
		draw_fixed_array(field_ptr, info.count, info.elem, field_tid, label)
	} else {
		im.TextColored(im.Vec4{1, 0, 0, 1}, "Not an array type")
	}
}

// is_array_type returns true if the typeid is a dynamic or fixed array.
is_array_type :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	_, is_dyn := ti.variant.(runtime.Type_Info_Dynamic_Array)
	_, is_fixed := ti.variant.(runtime.Type_Info_Array)
	return is_dyn || is_fixed
}

draw_fixed_array :: proc(ptr: rawptr, count: int, elem_ti: ^runtime.Type_Info, field_tid: typeid, label: cstring) {
	tree_open := im.TreeNode(label)
	draw_field_context_menu(ptr, field_tid)
	if !tree_open do return
	defer im.TreePop()
	im.TextDisabled("Fixed size: %d", count)
	for i in 0 ..< count {
		im.PushIDInt(c.int(i))
		elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_ti.size))
		sub_label := fmt.tprintf("[%d]", i)
		draw_array_element(elem_ptr, elem_ti.id, strings.clone_to_cstring(sub_label, context.temp_allocator))
		im.PopID()
	}
}

draw_dynamic_array :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info, field_ptr: rawptr, field_tid: typeid, label: cstring) {
	tree_open := im.TreeNode(label)
	draw_field_context_menu(field_ptr, field_tid)
	if !tree_open do return
	defer im.TreePop()
	im.TextDisabled("Size: %d", da.len)

	to_remove := -1
	for i in 0 ..< da.len {
		im.PushIDInt(c.int(i))
		im.AlignTextToFramePadding()
		im.Text("%d:", i)
		im.SameLine()
		elem_ptr := rawptr(uintptr(da.data) + uintptr(i * elem_ti.size))
		im.SetNextItemWidth(im.GetContentRegionAvail().x - 30)
		draw_array_element(elem_ptr, elem_ti.id, "##val")
		im.SameLine()
        if im.Button("x") {
			to_remove = i
		}
		im.PopID()
	}

	if im.Button("+ Add") {
		append_dynamic_array_element(da, elem_ti)
		mark_inspector_changed()
	}

	if to_remove >= 0 {
		remove_dynamic_array_element(da, elem_ti, to_remove)
		mark_inspector_changed()
	}
}

// draw_array_element draws one element using the same rules as the inspector: property drawer, struct recursion, or text.
draw_array_element :: proc(ptr: rawptr, elem_tid: typeid, label: cstring) {
	if drawer, ok := mapPropertyDrawer[elem_tid]; ok {
		drawer(ptr, elem_tid, label)
		draw_field_context_menu(ptr, elem_tid)
		return
	}
	elem_ti := type_info_of(elem_tid)
	if is_union_type(elem_tid) {
		draw_inspector_union(ptr, elem_tid, label)
		return
	}
	if reflect.is_struct(elem_ti) {
		elem_any := any{ptr, elem_tid}
		tree_open := im.TreeNode(label)
		draw_field_context_menu(ptr, elem_tid)
		if tree_open {
			draw_inspector(elem_any)
			im.TreePop()
		}
		return
	}
	elem_any := any{ptr, elem_tid}
	c_str := strings.clone_to_cstring(fmt.tprintf("%s: %v", label, elem_any), context.temp_allocator)
	im.Text(c_str)
	draw_field_context_menu(ptr, elem_tid)
}

append_dynamic_array_element :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info) -> bool {
	elem_size := elem_ti.size
	if elem_size == 0 do return false

	// Use context allocator if the array's allocator was never set (e.g. after JSON load or default-init)
	if da.allocator.procedure == nil do da.allocator = context.allocator

	new_len := da.len + 1
	if new_len > da.cap {
		new_cap := max(da.cap * 2, 1)
		new_data, err := mem.alloc(new_cap * elem_size, mem.DEFAULT_ALIGNMENT, da.allocator)
		if err != .None do return false
		if da.len > 0 do mem.copy(new_data, da.data, da.len * elem_size)
		old_data := da.data
		da.data = new_data
		da.cap = new_cap
		mem.free(old_data, da.allocator)
	}
	if da.data == nil do return false

	slot := rawptr(uintptr(da.data) + uintptr(da.len * elem_size))
	mem.zero(slot, elem_size)
	da.len = new_len
	return true
}

remove_dynamic_array_element :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info, index: int) {
	if index < 0 || index >= da.len do return
	elem_size := elem_ti.size
	src := rawptr(uintptr(da.data) + uintptr((index + 1) * elem_size))
	dst := rawptr(uintptr(da.data) + uintptr(index * elem_size))
	n_bytes := (da.len - 1 - index) * elem_size
	if n_bytes > 0 {
		mem.copy(dst, src, n_bytes)
	}
	last_slot := rawptr(uintptr(da.data) + uintptr((da.len - 1) * elem_size))
	mem.zero(last_slot, elem_size)
	da.len -= 1
}
