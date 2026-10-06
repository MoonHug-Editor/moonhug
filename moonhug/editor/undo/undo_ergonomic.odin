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

import core "moonhug:host/core"

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
edit_pooled_begin :: proc(h: core.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	if field_ptr == nil do return {}
	return edit_session_begin({edit_target_pooled(h, field_ptr, field_tid)}, label)
}

edit_transform_begin :: proc(tH: core.Transform_Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(core.Handle(tH), field_ptr, field_tid, label)
}

edit_component_begin :: proc(comp_handle: core.Handle, field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	return edit_pooled_begin(comp_handle, field_ptr, field_tid, label)
}

// The WHOLE component — structural edits (array add/remove, reorder) that no
// field offset can name.
edit_component_base :: proc(comp_handle: core.Handle, comp_tid: typeid, label := "") -> Edit_Scope {
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
