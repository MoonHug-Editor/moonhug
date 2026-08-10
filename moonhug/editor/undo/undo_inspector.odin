package undo

import "core:slice"
import engine "../../engine"

Inspector_Owner :: struct {
	kind:       Owner_Kind,
	scene:      Scene_Ref,
	local_id:   engine.Local_ID,
	handle:     engine.Handle,
	base_ptr:   rawptr,
	asset_guid: engine.Asset_GUID, // .Asset only
	asset_tid:  typeid,            // .Asset only: the document's typeid
	raw_tid:    typeid,            // .Raw only: enables whole-owner snapshots
}

@(private)
_owner_stack: [dynamic]Inspector_Owner

@(private)
_field_snapshot: Field_Snapshot

@(private)
_nested_depth: int

Field_Snapshot :: struct {
	active:   bool,
	target:   Property_Target,
	old_json: []byte,
	base_ptr: rawptr,
	prev_txn_depth: int,
}

push_owner :: proc(o: Inspector_Owner) {
	if _owner_stack == nil {
		_owner_stack = make([dynamic]Inspector_Owner)
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
	if _field_snapshot.active && _field_snapshot.old_json != nil {
		delete(_field_snapshot.old_json)
	}
	_field_snapshot = {}
	_nested_depth = 0
}

current_owner :: proc() -> (Inspector_Owner, bool) {
	if len(_owner_stack) == 0 do return {}, false
	return _owner_stack[len(_owner_stack) - 1], true
}

push_pooled_owner :: proc(h: engine.Handle) {
	w := engine.ctx_world()
	if w == nil {
		push_owner(Inspector_Owner{kind = .None})
		return
	}
	base := engine.world_pool_get(w, h)
	if base == nil {
		push_owner(Inspector_Owner{kind = .None})
		return
	}
	scene: ^engine.Scene
	lid: engine.Local_ID
	if h.type_key == .Transform {
		t := cast(^engine.Transform)base
		scene = t.scene
		lid = t.local_id
	} else {
		cbase := cast(^engine.CompData)base
		lid = cbase.local_id
		if t := engine.pool_get(&w.transforms, engine.Handle(cbase.owner)); t != nil {
			scene = t.scene
		}
	}
	push_owner(Inspector_Owner{
		kind = .Pooled,
		scene = scene_ref(scene),
		local_id = lid,
		handle = h,
		base_ptr = base,
	})
}

push_transform_owner :: proc(tH: engine.Transform_Handle) {
	push_pooled_owner(engine.Handle(tH))
}

push_component_owner :: proc(comp_handle: engine.Handle) {
	push_pooled_owner(comp_handle)
}

// A stable non-pooled struct (a project-settings var). `tid` may be nil:
// field edits still undo (target_for_field), but whole-owner snapshots
// (comp_snapshot — array ops, decorators, buttons) need the type.
push_raw_owner :: proc(base_ptr: rawptr, tid: typeid) {
	push_owner(Inspector_Owner{
		kind = .Raw,
		base_ptr = base_ptr,
		raw_tid = tid,
	})
}

// Asset document (project inspector): whole-document snapshots, applied back
// through the asset hook by guid — the doc pointer may be swapped by undo.
push_asset_owner :: proc(guid: engine.Asset_GUID, base_ptr: rawptr, tid: typeid) {
	push_owner(Inspector_Owner{
		kind = .Asset,
		base_ptr = base_ptr,
		asset_guid = guid,
		asset_tid = tid,
	})
}

edit_inspector_field_begin :: proc(field_ptr: rawptr, field_tid: typeid, label := "") -> Edit_Scope {
	o, ok := current_owner()
	if !ok || o.kind == .None do return {}
	if field_ptr == nil || field_tid == nil do return {}

	if o.kind == .Raw {
		if o.base_ptr == nil do return {}
		return edit_raw_begin(o.base_ptr, field_ptr, field_tid, label)
	}

	if o.kind == .Asset {
		return edit_asset_begin(o, label)
	}

	w := engine.ctx_world()
	if w == nil do return {}
	base_pool := engine.world_pool_get(w, o.handle)
	if base_pool == nil do return {}
	owner_tid := engine.get_typeid_by_type_key(o.handle.type_key)
	if owner_tid == nil do return {}
	owner_ti := type_info_of(owner_tid)
	field_ti := type_info_of(field_tid)
	fp := uintptr(field_ptr)
	bp := uintptr(base_pool)
	owner_lim := bp + uintptr(owner_ti.size)
	field_lim := fp + uintptr(field_ti.size)
	if fp >= bp && field_lim <= owner_lim && field_lim >= fp {
		return edit_pooled_begin(o.handle, field_ptr, field_tid, label)
	}
	return edit_pooled_begin(o.handle, base_pool, owner_tid, label)
}

// Whole-document edit scope for an .Asset owner (field context menus etc.):
// old/new payloads are the full document, applied back via the asset hook.
edit_asset_begin :: proc(o: Inspector_Owner, label := "") -> Edit_Scope {
	s := get()
	if s == nil || !s.recording || s.applying do return {}
	if o.base_ptr == nil || o.asset_tid == nil do return {}
	old_json := capture_json(o.base_ptr, o.asset_tid)
	if old_json == nil do return {}
	return Edit_Scope{
		active = true,
		target = make_asset_target(o.asset_guid, o.asset_tid),
		field_ptr = o.base_ptr,
		old_json = old_json,
		label = label,
	}
}

target_for_field :: proc(field_ptr: rawptr, field_tid: typeid) -> (Property_Target, bool) {
	o, ok := current_owner()
	if !ok || o.kind == .None || o.kind == .Asset do return {}, false
	if o.base_ptr == nil do return {}, false
	offset := uintptr(field_ptr) - uintptr(o.base_ptr)
	return Property_Target{
		kind     = o.kind,
		scene    = o.scene,
		local_id = o.local_id,
		handle   = o.handle,
		offset   = u32(offset),
		type_id  = field_tid,
		raw_ptr  = o.base_ptr if o.kind == .Raw else nil,
	}, true
}

begin_field :: proc(field_ptr: rawptr, field_tid: typeid) {
	_nested_depth += 1
	if _nested_depth > 1 do return
	_field_snapshot = {}
	s := get()
	if s == nil || !s.recording || s.applying do return
	if field_ptr == nil do return

	target, ok := target_for_field(field_ptr, field_tid)
	if !ok do return

	old_json := capture_json(field_ptr, field_tid)
	if old_json == nil do return

	_field_snapshot = Field_Snapshot{
		active   = true,
		target   = target,
		old_json = old_json,
		base_ptr = field_ptr,
		prev_txn_depth = len(s.txn_stack),
	}
}

end_field :: proc(changed: bool) {
	if _nested_depth > 0 {
		_nested_depth -= 1
	}
	if _nested_depth > 0 do return
	if !_field_snapshot.active {
		return
	}
	defer {
		delete(_field_snapshot.old_json)
		_field_snapshot = {}
	}
	s := get()
	if s == nil do return
	if !changed do return

	new_json := capture_json(_field_snapshot.base_ptr, _field_snapshot.target.type_id)
	if new_json == nil do return

	if slice.equal(_field_snapshot.old_json, new_json) {
		delete(new_json)
		return
	}

	old_copy := make([]byte, len(_field_snapshot.old_json))
	copy(old_copy, _field_snapshot.old_json)

	cmd: Value_Command = {target = _field_snapshot.target, old_json = old_copy, new_json = new_json}
	push(s, Command(cmd))
}

