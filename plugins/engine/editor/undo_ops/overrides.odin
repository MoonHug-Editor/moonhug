package undo_ops

// Prefab override bookkeeping as undo commands: the record half of a live edit
// on a prefab instance (Record_Override_Command, paired with the edit's own
// command in a group) and a row reverted from the Overrides dropdown.

import "core:fmt"
import "core:strings"
import engine "moonhug:packages/engine"
import core "moonhug:host/core"

// Bookkeeping for the prefab override that a live edit CREATED (see
// engine.nested_scene_record_override). Paired in a group with the
// Value_Command that changed the field: undoing the value must also take the
// override record away, or the field would read as overridden while holding
// its baseline value. Only ever recorded for a NEW entry — an edit that
// updated a pre-existing override leaves that override alone on undo.
// Which way the override record moved, so undo/redo can invert it. An edit
// that CREATED an override and a Revert that REMOVED one are the same
// bookkeeping in opposite directions.
Override_Record_Op :: enum {
	Created, // apply: record exists   / revert(undo): remove it
	Removed, // apply: record is gone  / revert(undo): put it back
	// Structural component edits on a prefab instance. The LIVE component is
	// created/destroyed by the paired Add_/Remove_Component_Command. These ops
	// only keep the NestedScene bookkeeping in step, so the edit also survives
	// the next resolve (which rebuilds the instance from its prefab).
	Comp_Removed, // apply: removal recorded / undo: retract the removal
	Comp_Added,   // apply: addition recorded / undo: retract the addition
	Obj_Removed,  // same, for an OBJECT (transform subtree) the instance lacks
}

@(undo_command)
Record_Override_Command :: struct {
	scene:         core.Scene_Ref,
	host_local_id: engine.Local_ID, // NS host transform, resolved on apply
	target_lid:    engine.Local_ID, // live lid of the overridden row
	property_path: string,          // owned
	op:            Override_Record_Op,
	// .Removed only: the entries Revert deleted, verbatim, so undo restores
	// them exactly (a revert can clear several paths under one field).
	removed:       []Removed_Override, // owned
	// .Comp_Added only: what rebuilding the addition record needs on redo. The
	// live component is re-created by the paired Add_Component_Command. These
	// carry the data the NestedScene record itself needs.
	owner_lid:       engine.Local_ID,
	comp_type_guid:  string, // owned
	comp_json:       string, // owned
}

apply_Record_Override_Command :: proc(v: ^Record_Override_Command) {
	// REDO: put the record back the way the original action left it.
	switch v.op {
	case .Created:
		// The value sub-command restored the edited value, so the record
		// comes back with it.
		_override_record_reapply(v^)
	case .Removed:
		_override_record_rerevert(v^)
	case .Comp_Removed:
		_comp_removal_record(v^)
	case .Comp_Added:
		_comp_addition_record(v^)
	case .Obj_Removed:
		_obj_removal_record(v^)
	}
}

revert_Record_Override_Command :: proc(v: ^Record_Override_Command) {
	// UNDO: invert whatever the action did to the record.
	switch v.op {
	case .Created:
		// Drop the override this edit introduced — the paired
		// Value_Command puts the old value back, so leaving the record
		// would mark the field overridden while it holds its baseline.
		_override_record_remove(v^)
	case .Removed:
		// Undo of a Revert: the value command restores the overridden
		// value, so the record must come back too.
		_override_record_restore(v^)
	case .Comp_Removed:
		// The paired Remove_Component_Command re-created the component.
		// Retract the removal so a resolve keeps it.
		_comp_removal_retract(v^)
	case .Comp_Added:
		// The paired Add_Component_Command destroyed the component.
		// Retract the addition record with it.
		_comp_addition_retract(v^)
	case .Obj_Removed:
		// The paired Delete_Subtree_Command restored the subtree.
		// Retract the suppression so a resolve keeps it.
		_obj_removal_retract(v^)
	}
}

destroy_Record_Override_Command :: proc(v: ^Record_Override_Command) {
	delete(v.property_path)
	delete(v.comp_type_guid)
	delete(v.comp_json)
	for r in v.removed {
		delete(r.property_path)
		delete(r.value_json)
	}
	if v.removed != nil do delete(v.removed)
}

// Never the label of a step on its own: it always rides the value command's
// group, which supplies the label.
label_Record_Override_Command :: proc(v: ^Record_Override_Command) -> string {
	return "Prefab Override"
}

scenes_Record_Override_Command :: proc(v: ^Record_Override_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Record_Override_Command :: proc(v: ^Record_Override_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sPrefab override created: lid %v %q\n",
		_indent(depth), v.target_lid, v.property_path)
}

Removed_Override :: struct {
	target:        engine.PPtr,
	property_path: string,     // owned
	value_json:    []byte,     // owned, the override's value re-marshaled
}

// Frees a snapshot of Revert-deleted override entries.
discard_override_removal :: proc(snap: []Removed_Override) {
	for r in snap {
		delete(r.property_path)
		delete(r.value_json)
	}
	if snap != nil do delete(snap)
}

// One row reverted from the Overrides dropdown. Unlike Record_Override_Command
// this stands ALONE: the dropdown drops a record without a paired live-world
// command, so undo has to rebuild the record from a snapshot rather than lean
// on a Value_/Add_/Remove_ command to restore the world half.
//
// Field rows still carry `removed` (the value must come back with the record),
// structural rows carry the engine snapshot of the record itself.
@(undo_command)
Dropdown_Revert_Command :: struct {
	scene:         core.Scene_Ref,
	host_local_id: engine.Local_ID,
	kind:          engine.Override_Entry_Kind,
	// Modified_Property
	target:        engine.PPtr,
	property_path: string,             // owned
	removed:       []Removed_Override, // owned
	// structural kinds
	snapshot:      engine.Override_Snapshot, // owns its clones
}

apply_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command) {
	_dropdown_revert_apply(v^) // REDO: drop the record again
}

revert_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command) {
	_dropdown_revert_undo(v^)
}

destroy_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command) {
	delete(v.property_path)
	discard_override_removal(v.removed)
	v.removed = nil
	engine.nested_override_snapshot_destroy(&v.snapshot)
}

label_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command) -> string {
	return "Revert Override"
}

scenes_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Dropdown_Revert_Command :: proc(v: ^Dropdown_Revert_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sOverride reverted (%v): %q\n",
		_indent(depth), v.kind, v.property_path)
}

@(private)
_override_host :: proc(v: Record_Override_Command) -> (^engine.Scene, engine.Transform_Handle, bool) {
	s := _scene(v.scene)
	if s == nil do return nil, {}, false
	if h, ok := engine.bimap_get(&s.local_ids, v.host_local_id); ok && h.type_key == .Transform {
		return s, engine.Transform_Handle(h), true
	}
	// A ROOT VARIANT's base content is loaded with lid registration skipped, so
	// the base root — which IS the scene root — has no bimap entry. Match it
	// directly rather than failing, or undo of a revert silently does nothing.
	if rt := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(s.root.handle));
	   rt != nil && rt.local_id == v.host_local_id {
		return s, engine.Transform_Handle(s.root.handle), true
	}
	return nil, {}, false
}

// The NS the dropdown's rows came from. Resolved on each apply/undo rather
// than stored, because a scene reload replaces the NestedScene values.
@(private)
_dropdown_revert_ns :: proc(v: Dropdown_Revert_Command) -> (^engine.Scene, ^engine.NestedScene, bool) {
	s := _scene(v.scene)
	if s == nil do return nil, nil, false
	h, ok := engine.bimap_get(&s.local_ids, v.host_local_id)
	if !ok || h.type_key != .Transform do return nil, nil, false
	ns := engine.scene_find_nested_scene_for_host(s, engine.Transform_Handle(h))
	if ns == nil do return nil, nil, false
	return s, ns, true
}

// REDO: re-run the revert.
@(private)
_dropdown_revert_apply :: proc(v: Dropdown_Revert_Command) {
	s, ns, ok := _dropdown_revert_ns(v)
	if !ok do return
	if v.kind == .Modified_Property {
		engine.nested_scene_revert_override(s, ns, v.target, v.property_path)
		return
	}
	engine.nested_override_entry_revert(s, ns, engine.Override_Entry{
		kind     = v.kind,
		target   = v.snapshot.target,
		owner    = v.snapshot.owner,
		local_id = v.snapshot.local_id,
	})
}

// UNDO: put the reverted record back. A field row restores its value entries
// verbatim (a revert can clear several paths under one field), a structural row
// rebuilds from the engine snapshot.
@(private)
_dropdown_revert_undo :: proc(v: Dropdown_Revert_Command) {
	s, ns, ok := _dropdown_revert_ns(v)
	if !ok do return
	if v.kind == .Modified_Property {
		for r in v.removed {
			engine.nested_override_restore_field(s, ns, r.target, r.property_path, r.value_json)
		}
		return
	}
	engine.nested_override_snapshot_restore(ns, v.snapshot)
}

@(private)
_override_record_remove :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_unrecord_override_for_host(s, host, v.target_lid, v.property_path)
}

@(private)
_override_record_reapply :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	// Re-record from the live field, which the paired Value_Command has
	// already restored to the overridden value by now (subs apply in order).
	ptr, tid, found := engine.nested_scene_find_live_field(s, host, v.target_lid, v.property_path)
	if !found || ptr == nil do return
	engine.nested_scene_record_override_for_host(s, host, v.target_lid, v.property_path, ptr, tid)
}

// Puts back exactly the entries a Revert deleted (captured at revert time).
@(private)
_override_record_restore :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	root_ns, _, loc_ok := engine.nested_scene_locate_root_override(s, host, v.target_lid)
	if !loc_ok || root_ns == nil do return
	for r in v.removed {
		engine.nested_scene_restore_override(root_ns, r.target, r.property_path, r.value_json)
	}
}

// Re-runs the Revert's record removal (redo of a Revert).
@(private)
_override_record_rerevert :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	root_ns, _, loc_ok := engine.nested_scene_locate_root_override(s, host, v.target_lid)
	if !loc_ok || root_ns == nil do return
	for r in v.removed {
		engine.nested_scene_unrecord_override(root_ns, r.target, r.property_path)
	}
}

// --- Structural component-edit bookkeeping ------------------------------------
// The live component is handled by the paired Add_/Remove_Component_Command.
// These only add or retract the NestedScene record, so the edit survives the
// next resolve.

@(private)
_comp_removal_record :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_record_component_removed(s, host, v.target_lid)
}

@(private)
_comp_removal_retract :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_unrecord_component_removed(s, host, v.target_lid)
}

@(private)
_obj_removal_record :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_record_object_removed(s, host, v.target_lid)
}

@(private)
_obj_removal_retract :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_unrecord_object_removed(s, host, v.target_lid)
}

@(private)
_comp_addition_record :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	root_ns, owner_target, loc_ok := engine.nested_scene_locate_root_override(s, host, v.owner_lid)
	if !loc_ok || root_ns == nil do return
	engine.nested_scene_restore_component_added(
		root_ns, owner_target, v.target_lid, v.comp_type_guid, v.comp_json,
	)
}

@(private)
_comp_addition_retract :: proc(v: Record_Override_Command) {
	s, host, ok := _override_host(v)
	if !ok do return
	engine.nested_scene_unrecord_component_added(s, host, v.target_lid)
}
