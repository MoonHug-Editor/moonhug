package undo

// The ergonomic edit: two lines around a change to ONE field or ONE whole
// component/transform.
//
//   e := undo.edit_begin(tH, &t.name, typeid_of(string))
//   t.name = ...
//   undo.edit_end(&e)
//
// An Edit_Scope IS an Edit_Session with a single target — the same
// transaction the inspector rows and multi-edit use (undo_session.odin), so
// every call site shares one implementation: before-state captured at open,
// the field-vs-whole granularity decided by the session (a dynamic-array
// element is recorded as its whole component, never as an offset into an
// allocation it does not live in), nothing recorded when the value did not
// change. Reach for edit_session_begin directly when a gesture spans several
// targets.

import engine "../../engine"

Edit_Scope :: Edit_Session

edit_begin :: proc {
	edit_transform_begin,
	edit_component_begin,
	edit_raw_begin,
	edit_component_base,
}

edit_end :: edit_session_end
edit_cancel :: edit_session_abort

// A field of a pooled component or transform.
edit_pooled_begin :: proc(h: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	if field_ptr == nil do return {}
	return edit_session_begin({edit_target_pooled(h, field_ptr, field_tid)}, label)
}

edit_transform_begin :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(engine.Handle(tH), field_ptr, field_tid, label)
}

edit_component_begin :: proc(comp_handle: engine.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(comp_handle, field_ptr, field_tid, label)
}

// The WHOLE component — structural edits (array add/remove, reorder) that no
// field offset can name.
edit_component_base :: proc(comp_handle: engine.Handle, comp_tid: typeid, label := "") -> Edit_Scope {
	return edit_session_begin({edit_target_whole(comp_handle)}, label)
}

// A field of a plain editor-owned struct (import settings, project settings).
// `base_tid` is the struct's type: the session needs it to decide whether the
// field lies inside the struct (recorded as an offset) or outside it (the
// whole struct is recorded) — the same rule pooled targets get.
edit_raw_begin :: proc(base_ptr: rawptr, base_tid: typeid, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	if base_ptr == nil || base_tid == nil || field_ptr == nil do return {}
	return edit_session_begin({Edit_Target{
		kind = .Raw, raw_ptr = base_ptr, raw_tid = base_tid,
		field_ptr = field_ptr, field_tid = field_tid,
	}}, label)
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

	// A sibling reorder keeps its locals untouched; a real parent change
	// keeps the WORLD transform (Unity's worldPositionStays), so the
	// rewritten locals land in the same undo step as the reparent.
	if new_parent == old_parent {
		engine.transform_set_parent(node, new_parent, new_index)
		final_index := engine.transform_get_sibling_index(node)
		record_reparent(node, old_parent, new_parent, old_index, final_index)
		return
	}

	g := group_begin("Reparent")
	defer group_end(&g)
	locals := edit_session_begin({
		edit_target_transform(node, &t.position, typeid_of([3]f32)),
		edit_target_transform(node, &t.rotation, typeid_of([4]f32)),
		edit_target_transform(node, &t.scale, typeid_of([3]f32)),
	}, "Reparent")

	engine.transform_set_parent(node, new_parent, new_index, keep_world = true)
	final_index := engine.transform_get_sibling_index(node)
	record_reparent(node, old_parent, new_parent, old_index, final_index)

	edit_session_end(&locals)
	group_commit(&g)
}
