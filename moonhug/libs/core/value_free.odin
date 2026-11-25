package core

// Frees the memory a value owns, everything reachable through its strings,
// slices, dynamic arrays and maps, nested in any depth. Pointers, procs and
// `any` are left alone: the value does not own what they point at.
//
// `owned` says whether a block may be freed. A value can hold memory it does
// not own (a string field still pointing at its default literal), so only the
// blocks `owned` accepts are freed. The debug editor frees its process-long
// settings at exit this way, asking its tracking allocator, so they do not
// show in the leak report (editor/leak_report.odin).

import "base:runtime"

value_free :: proc(ptr: rawptr, tid: typeid, owned: proc(block: rawptr) -> bool) {
	if ptr == nil || tid == nil do return
	_value_free(ptr, type_info_of(tid), owned)
}

@(private = "file")
_value_free :: proc(ptr: rawptr, ti: ^runtime.Type_Info, owned: proc(block: rawptr) -> bool) {
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		if v.is_cstring {
			c := (^cstring)(ptr)^
			if c != nil && owned(rawptr(c)) do free(rawptr(c))
			return
		}
		s := (^runtime.Raw_String)(ptr)
		if s.data != nil && owned(s.data) do free(s.data)
		s^ = {}
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			_value_free(rawptr(uintptr(ptr) + v.offsets[i]), v.types[i], owned)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count do _value_free(rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem, owned)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count do _value_free(rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem, owned)
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(ptr)
		for i in 0 ..< s.len do _value_free(rawptr(uintptr(s.data) + uintptr(i * v.elem_size)), v.elem, owned)
		if s.data != nil && owned(s.data) do free(s.data)
		s^ = {}
	case runtime.Type_Info_Dynamic_Array:
		d := (^runtime.Raw_Dynamic_Array)(ptr)
		for i in 0 ..< d.len do _value_free(rawptr(uintptr(d.data) + uintptr(i * v.elem_size)), v.elem, owned)
		if d.data != nil && owned(d.data) do runtime.mem_free(d.data, d.allocator)
		d^ = {}
	case runtime.Type_Info_Map:
		m := (^runtime.Raw_Map)(ptr)
		if m.data == 0 do return
		info := v.map_info
		capacity := uintptr(runtime.map_cap(m^))
		ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m^, info)
		for i in 0 ..< capacity {
			if !runtime.map_hash_is_valid(hs[i]) do continue
			_value_free(rawptr(runtime.map_cell_index_dynamic(ks, info.ks, i)), v.key, owned)
			_value_free(rawptr(runtime.map_cell_index_dynamic(vs, info.vs, i)), v.value, owned)
		}
		if owned(rawptr(runtime.map_data(m^))) do _ = runtime.map_free_dynamic(m^, info)
		m^ = {}
	case runtime.Type_Info_Union:
		if len(v.variants) == 0 do return
		tag_ptr := uintptr(ptr) + v.tag_offset
		tag: i64
		switch v.tag_type.size {
		case 1: tag = i64((^u8)(tag_ptr)^)
		case 2: tag = i64((^u16)(tag_ptr)^)
		case 4: tag = i64((^u32)(tag_ptr)^)
		case 8: tag = i64((^u64)(tag_ptr)^)
		}
		index := tag if v.no_nil else tag - 1
		if index < 0 || index >= i64(len(v.variants)) do return
		_value_free(ptr, v.variants[index], owned)
	}
}
