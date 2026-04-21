package undo

import engine "../../engine"

Edit_Scope :: struct {
	active:    bool,
	target:    Property_Target,
	field_ptr: rawptr,
	old_json:  []byte,
	label:     string,
}

edit_begin :: proc {
	edit_transform_begin,
	edit_component_begin,
	edit_raw_begin,
	edit_component_base,
}

field_drag_begin :: proc {
	field_drag_begin_transform,
	field_drag_begin_component,
}

edit_pooled_begin :: proc(h: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	s := get()
	if s == nil || !s.recording || s.applying || field_ptr == nil {
		return {}
	}
	w := engine.ctx_world()
	if w == nil do return {}
	base := engine.world_pool_get(w, h)
	if base == nil do return {}
	offset := uintptr(field_ptr) - uintptr(base)
	target := make_pooled_target(h, offset, field_tid)
	old_json := capture_json(field_ptr, field_tid)
	if old_json == nil do return {}
	return Edit_Scope{
		active = true,
		target = target,
		field_ptr = field_ptr,
		old_json = old_json,
		label = label,
	}
}

edit_transform_begin :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(engine.Handle(tH), field_ptr, field_tid, label)
}

edit_component_begin :: proc(comp_handle: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(comp_handle, field_ptr, field_tid, label)
}

edit_component_base :: proc(comp_handle: engine.Handle, comp_tid: typeid, label := "") -> Edit_Scope {
	w := engine.ctx_world()
	if w == nil do return {}
	base := engine.world_pool_get(w, comp_handle)
	if base == nil do return {}
	return edit_pooled_begin(comp_handle, base, comp_tid, label)
}

edit_raw_begin :: proc(base_ptr: rawptr, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	s := get()
	if s == nil || !s.recording || s.applying || field_ptr == nil || base_ptr == nil {
		return {}
	}
	offset := uintptr(field_ptr) - uintptr(base_ptr)
	target := make_raw_target(base_ptr, offset, field_tid)
	old_json := capture_json(field_ptr, field_tid)
	if old_json == nil do return {}
	return Edit_Scope{
		active = true,
		target = target,
		field_ptr = field_ptr,
		old_json = old_json,
		label = label,
	}
}

edit_end :: proc(e: ^Edit_Scope) {
	if e == nil || !e.active do return
	defer e^ = {}
	s := get()
	if s == nil {
		if e.old_json != nil do delete(e.old_json)
		return
	}
	new_json := capture_json(e.field_ptr, e.target.type_id)
	push_value(s, e.target, e.old_json, new_json, e.label)
}

edit_cancel :: proc(e: ^Edit_Scope) {
	if e == nil || !e.active do return
	if e.old_json != nil do delete(e.old_json)
	e^ = {}
}

Group_Scope :: struct {
	active:    bool,
	aborted:   bool,
	committed: bool,
	label:     string,
}

group_begin :: proc(label := "") -> Group_Scope {
	s := get()
	if s == nil || !s.recording || s.applying {
		return {}
	}
	begin_group_command(s, label)
	return Group_Scope{active = true, label = label}
}

group_end :: proc(g: ^Group_Scope) {
	if g == nil || !g.active do return
	defer g^ = {}
	s := get()
	if s == nil do return
	if g.aborted || !g.committed {
		abort_group_command(s)
		return
	}
	end_group_command(s, g.label)
}

group_commit :: proc(g: ^Group_Scope) {
	if g == nil do return
	g.committed = true
}

group_abort :: proc(g: ^Group_Scope) {
	if g == nil do return
	g.aborted = true
}

record_delete :: proc(tH: engine.Transform_Handle) {
	pre, ok := record_delete_pre(tH)
	if !ok {
		engine.transform_destroy(tH)
		return
	}
	engine.transform_destroy(tH)
	record_commit(&pre)
}

record_remove_component :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle) {
	list_idx := -1
	w := engine.ctx_world()
	if w != nil {
		if t := engine.pool_get(&w.transforms, engine.Handle(owner_tH)); t != nil {
			for i in 0 ..< len(t.components) {
				if t.components[i].handle == comp_handle {
					list_idx = i
					break
				}
			}
		}
	}
	pre, ok := record_remove_component_pre(owner_tH, comp_handle, list_idx)
	if !ok {
		engine.transform_remove_comp(owner_tH, comp_handle)
		return
	}
	engine.transform_remove_comp(owner_tH, comp_handle)
	record_commit(&pre)
}

record_create_child :: proc(name: string, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	if tH != {} {
		record_create(tH, parent)
	}
	return tH
}

record_reparent_to :: proc(node: engine.Transform_Handle, new_parent: engine.Transform_Handle, new_index: int = -1) {
	w := engine.ctx_world()
	if w == nil do return
	t := engine.pool_get(&w.transforms, engine.Handle(node))
	if t == nil do return
	old_parent := engine.Transform_Handle(t.parent.handle)
	old_index := engine.transform_get_sibling_index(node)
	engine.transform_set_parent(node, new_parent, new_index)
	final_index := engine.transform_get_sibling_index(node)
	record_reparent(node, old_parent, new_parent, old_index, final_index)
}

Field_Drag :: struct {
	active:    bool,
	target:    Property_Target,
	field_ptr: rawptr,
	old_json:  []byte,
	label:     string,
}

field_drag_begin_pooled :: proc(h: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Field_Drag {
	e := edit_pooled_begin(h, field_ptr, field_tid, label)
	return Field_Drag{active = e.active, target = e.target, field_ptr = e.field_ptr, old_json = e.old_json, label = e.label}
}

field_drag_begin_transform :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Field_Drag {
	return field_drag_begin_pooled(engine.Handle(tH), field_ptr, field_tid, label)
}

field_drag_begin_component :: proc(comp_handle: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Field_Drag {
	return field_drag_begin_pooled(comp_handle, field_ptr, field_tid, label)
}

field_drag_end :: proc(d: ^Field_Drag) {
	if d == nil || !d.active do return
	defer d^ = {}
	s := get()
	if s == nil {
		if d.old_json != nil do delete(d.old_json)
		return
	}
	new_json := capture_json(d.field_ptr, d.target.type_id)
	push_value(s, d.target, d.old_json, new_json, d.label)
}

field_drag_cancel :: proc(d: ^Field_Drag) {
	if d == nil || !d.active do return
	if d.old_json != nil do delete(d.old_json)
	d^ = {}
}
