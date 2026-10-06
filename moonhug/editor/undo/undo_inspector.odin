package undo

import "base:runtime"
import core "moonhug:host/core"

Inspector_Owner :: struct {
	kind:       Owner_Kind,
	scene:      Scene_Ref,
	local_id:   core.Local_ID,
	handle:     core.Handle,
	base_ptr:   rawptr,
	asset_guid: core.Asset_GUID, // .Asset only
	asset_tid:  typeid,            // .Asset only: the document's typeid
	asset_doc:  Doc_Kind,          // .Asset only
	raw_tid:    typeid,            // .Raw only: enables whole-owner snapshots
}

@(private)
_owner_stack: [dynamic]Inspector_Owner

push_owner :: proc(o: Inspector_Owner) {
	if _owner_stack == nil {
		// Process-global: never borrows the caller's allocator.
		_owner_stack = make([dynamic]Inspector_Owner, runtime.default_allocator())
	}
	append(&_owner_stack, o)
}

pop_owner :: proc() {
	if len(_owner_stack) == 0 do return
	pop(&_owner_stack)
}

inspector_shutdown :: proc() {
	if _owner_stack != nil {
		delete(_owner_stack)
		_owner_stack = nil
	}
}

current_owner :: proc() -> (Inspector_Owner, bool) {
	if len(_owner_stack) == 0 do return {}, false
	return _owner_stack[len(_owner_stack) - 1], true
}

push_pooled_owner :: proc(h: core.Handle) {
	push_owner(pooled_owner(h))
}

// The owner record for a pooled transform or component, without pushing it —
// for a caller that carries the owner around (inspector.Property) and pushes
// it only while a row draws. `.None` when the handle is dead.
pooled_owner :: proc(h: core.Handle) -> Inspector_Owner {
	t := make_pooled_target(h, 0, nil)
	base, _, ok := resolve_pooled_base(t)
	if !ok do return Inspector_Owner{kind = .None}
	return Inspector_Owner{
		kind = .Pooled,
		scene = t.scene,
		local_id = t.local_id,
		handle = h,
		base_ptr = base,
	}
}

push_transform_owner :: proc(tH: core.Transform_Handle) {
	push_pooled_owner(core.Handle(tH))
}

push_component_owner :: proc(comp_handle: core.Handle) {
	push_pooled_owner(comp_handle)
}

// A stable non-pooled struct (a project-settings var). `tid` may be nil for
// field-only edits; whole-owner sessions (array ops, decorators, buttons) need
// the type to capture the struct.
push_raw_owner :: proc(base_ptr: rawptr, tid: typeid) {
	push_owner(Inspector_Owner{
		kind = .Raw,
		base_ptr = base_ptr,
		raw_tid = tid,
	})
}

// Asset document (project inspector): whole-document snapshots, applied back
// through the asset hook by guid — the doc pointer may be swapped by undo.
push_asset_owner :: proc(guid: core.Asset_GUID, base_ptr: rawptr, tid: typeid, doc := Doc_Kind.File) {
	push_owner(Inspector_Owner{
		kind = .Asset,
		base_ptr = base_ptr,
		asset_guid = guid,
		asset_tid = tid,
		asset_doc = doc,
	})
}

// edit_begin for the field under the inspector's CURRENT OWNER (the stack
// push_*_owner maintains): the owner decides whether the field belongs to a
// pooled component, an asset document or a plain struct, and the session
// decides the granularity from there — the same derivation field_edit_begin
// makes for inspector rows.
edit_inspector_field_begin :: proc(field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	o, ok := current_owner()
	if !ok || field_ptr == nil || field_tid == nil do return {}
	target: Edit_Target
	switch o.kind {
	case .None:
		return {}
	case .Pooled:
		target = edit_target_pooled(o.handle, field_ptr, field_tid)
	case .Asset:
		target = edit_target_asset(o.asset_guid, o.asset_tid, o.asset_doc)
	case .Raw:
		if o.base_ptr == nil do return {}
		target = Edit_Target{
			kind = .Raw, raw_ptr = o.base_ptr, raw_tid = o.raw_tid,
			field_ptr = field_ptr, field_tid = field_tid,
		}
	}
	return edit_session_begin({target}, label)
}
