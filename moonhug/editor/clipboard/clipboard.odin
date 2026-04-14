package clipboard

import "../../engine/json"
import "core:fmt"
import "core:reflect"
import engine "../../engine"
import ser "../../engine/serialization"
import "../../engine/log"

Clipboard :: struct {
	json_data:      [dynamic]byte,
	json_tid:       typeid,
	hierarchy_data: []byte,
}

@(private)
_clipboard: Clipboard

init :: proc() {
	_clipboard.json_data = make([dynamic]byte)
}

copy :: proc(v: any) -> bool {
	x, ok := _resolve_any(v)
	if !ok {
		log.error("clipboard.copy: could not resolve value")
		return false
	}
	ptr := x.data
	tid := x.id
	if ptr == nil || tid == nil {
		return false
	}

	ser.Run_Before_Serialize(ptr, tid, false)
	defer ser.Run_Before_Serialize(ptr, tid, true)
	opts := json.Marshal_Options {
		spec       = .JSON,
		pretty     = false,
		use_spaces = false,
		spaces     = 0,
	}
	bytes, err := json.marshal(x, opts, allocator = context.allocator)
	if err != nil {
		log.error(fmt.tprintf("clipboard.copy: marshal failed: %v", err))
		return false
	}
	defer delete(bytes)

	clear(&_clipboard.json_data)
	append(&_clipboard.json_data, ..bytes)
	_clipboard.json_tid = tid
	return true
}

has :: proc() -> bool {
	return len(_clipboard.json_data) > 0 && _clipboard.json_tid != nil
}

target_typeid :: proc() -> typeid {
	return _clipboard.json_tid
}

can_paste :: proc(tid: typeid) -> bool {
	return len(_clipboard.json_data) > 0 && _clipboard.json_tid == tid && tid != nil
}

paste :: proc(dst: any) -> bool {
	if len(_clipboard.json_data) == 0 || _clipboard.json_tid == nil {
		return false
	}
	x, ok := _resolve_any(dst)
	if !ok {
		return false
	}
	if x.id != _clipboard.json_tid {
		return false
	}
	ptr := x.data
	tid := x.id
	ptr_tid, ptr_tid_ok := engine.get_pointer_typeid_by_typeid(tid)
	if !ptr_tid_ok {
		log.error(fmt.tprintf("clipboard.paste: no pointer typeid registered for %v — call engine.register_pointer_type($T) during init", tid))
		return false
	}
	target := any{data = &ptr, id = ptr_tid}
	um_err := json.unmarshal_any(_clipboard.json_data[:], target, json.DEFAULT_SPECIFICATION, context.allocator)
	if um_err != nil {
		log.error(fmt.tprintf("clipboard.paste: unmarshal failed: %v", um_err))
		return false
	}
	ser.Run_After_Deserialize(ptr, tid)
	return true
}

copy_hierarchy :: proc(data: []byte) {
	delete(_clipboard.hierarchy_data)
	_clipboard.hierarchy_data = data
}

paste_hierarchy :: proc() -> []byte {
	return _clipboard.hierarchy_data
}

has_hierarchy :: proc() -> bool {
	return len(_clipboard.hierarchy_data) > 0
}

@(private)
_resolve_any :: proc(v: any) -> (any, bool) {
	x := v
	for _ in 0 ..< 32 {
		if x.data == nil {
			return {}, false
		}
		ti := type_info_of(x.id)
		if ti == nil {
			return {}, false
		}
		if !reflect.is_pointer(ti) {
			return x, true
		}
		x = reflect.deref(x)
	}
	return {}, false
}
