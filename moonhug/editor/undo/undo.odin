package undo

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "base:builtin"
import engine "../../engine"
import "../../engine/log"

MAX_ENTRIES :: 128

Owner_Kind :: enum {
	None,
	Pooled,
	Raw,
	Asset, // serialized asset document (.mat/.asset), identified by asset guid
}

// Scene identity that survives scene reloads: the pointer is the fast path
// while the scene stays loaded; the asset guid re-finds the reloaded scene
// afterwards (empty for never-saved scenes — those can't outlive an unload,
// purge_* removes their entries).
Scene_Ref :: struct {
	ptr:  ^engine.Scene,
	guid: engine.Asset_GUID,
}

scene_ref :: proc(s: ^engine.Scene) -> Scene_Ref {
	if s == nil do return {}
	return Scene_Ref{ptr = s, guid = s.asset_guid}
}

resolve_scene :: proc(r: Scene_Ref) -> ^engine.Scene {
	if engine.sm_scene_is_loaded(r.ptr) do return r.ptr
	return engine.sm_scene_find_by_guid(r.guid)
}

Property_Target :: struct {
	kind:       Owner_Kind,
	scene:      Scene_Ref,
	local_id:   engine.Local_ID,
	handle:     engine.Handle,
	offset:     u32,
	type_id:    typeid,
	raw_ptr:    rawptr,
	asset_guid: engine.Asset_GUID, // .Asset only
}

Value_Command :: struct {
	target:   Property_Target,
	old_json: []byte,
	new_json: []byte,
}

Reparent_Command :: struct {
	scene:                Scene_Ref,
	node_local_id:        engine.Local_ID,
	old_parent_local_id:  engine.Local_ID,
	new_parent_local_id:  engine.Local_ID,
	old_index:            int,
	new_index:            int,
}

Create_Subtree_Command :: struct {
	scene:               Scene_Ref,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
}

Delete_Subtree_Command :: struct {
	scene:               Scene_Ref,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
	// The subtree was PREFAB CONTENT (nested_owned). Restoring it has to put
	// that back, or the next save would treat the restored rows as a host
	// addition and emit them into the host file.
	nested_owned:        bool,
}

Add_Component_Command :: struct {
	scene:               Scene_Ref,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

Remove_Component_Command :: struct {
	scene:               Scene_Ref,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

Reorder_Components_Command :: struct {
	scene:               Scene_Ref,
	owner_local_id:      engine.Local_ID,
	old_index:           int,
	new_index:           int,
}

// Removal of a PRESERVED unknown-component record (the component's package
// isn't compiled in — no type_key, no live pool instance). `payload` is the
// marshaled record; undo re-stashes it verbatim.
Remove_Unknown_Component_Command :: struct {
	scene:               Scene_Ref,
	owner_local_id:      engine.Local_ID,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

Structural_Command :: union {
	Reparent_Command,
	Create_Subtree_Command,
	Delete_Subtree_Command,
	Add_Component_Command,
	Remove_Component_Command,
	Reorder_Components_Command,
	Remove_Unknown_Component_Command,
}

Group_Command :: struct {
	subs: [dynamic]Command,
}

Selection_Scene_Item :: struct {
	scene:    Scene_Ref,
	local_id: engine.Local_ID,
}

// Snapshot of the editor selection (both domains, ordered, last = active).
// Slices and strings are owned by the command.
Selection_State :: struct {
	scene: []Selection_Scene_Item,
	proj:  []string,
}

// A selection change as its own undo step (Unity model): undo applies
// `before`, redo applies `after`. Restoration goes through the editor-side
// hook installed with set_selection_hooks.
Selection_Command :: struct {
	before: Selection_State,
	after:  Selection_State,
}

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
	// created/destroyed by the paired Add_/Remove_Component_Command; these ops
	// only keep the NestedScene bookkeeping in step, so the edit also survives
	// the next resolve (which rebuilds the instance from its prefab).
	Comp_Removed, // apply: removal recorded / undo: retract the removal
	Comp_Added,   // apply: addition recorded / undo: retract the addition
	Obj_Removed,  // same, for an OBJECT (transform subtree) the instance lacks
}

Record_Override_Command :: struct {
	scene:         Scene_Ref,
	host_local_id: engine.Local_ID, // NS host transform, resolved on apply
	target_lid:    engine.Local_ID, // live lid of the overridden row
	property_path: string,          // owned
	op:            Override_Record_Op,
	// .Removed only: the entries Revert deleted, verbatim, so undo restores
	// them exactly (a revert can clear several paths under one field).
	removed:       []Removed_Override, // owned
	// .Comp_Added only: what rebuilding the addition record needs on redo. The
	// live component is re-created by the paired Add_Component_Command; these
	// carry the data the NestedScene record itself needs.
	owner_lid:       engine.Local_ID,
	comp_type_guid:  string, // owned
	comp_json:       string, // owned
}

Removed_Override :: struct {
	target:        engine.PPtr,
	property_path: string,     // owned
	value_json:    []byte,     // owned; the override's value re-marshaled
}

// One row reverted from the Overrides dropdown. Unlike Record_Override_Command
// this stands ALONE: the dropdown drops a record without a paired live-world
// command, so undo has to rebuild the record from a snapshot rather than lean
// on a Value_/Add_/Remove_ command to restore the world half.
//
// Field rows still carry `removed` (the value must come back with the record);
// structural rows carry the engine snapshot of the record itself.
Dropdown_Revert_Command :: struct {
	scene:         Scene_Ref,
	host_local_id: engine.Local_ID,
	kind:          engine.Override_Entry_Kind,
	// Modified_Property
	target:        engine.PPtr,
	property_path: string,             // owned
	removed:       []Removed_Override, // owned
	// structural kinds
	snapshot:      engine.Override_Snapshot, // owns its clones
}

Command :: union {
	Value_Command,
	Structural_Command,
	Group_Command,
	Selection_Command,
	Record_Override_Command,
	Dropdown_Revert_Command,
}

Entry :: struct {
	label: string,
	cmd:   Command,
}

Undo_Stack :: struct {
	items:      [dynamic]Entry,
	top:        int,
	txn_stack:  [dynamic]Group_Command,
	recording:  bool,
	applying:   bool,
	// Set by every stack mutation (push, undo/redo, clear, purge); consumed
	// once per frame by the editor's selection tracker so selection changes
	// caused by data operations don't also record as selection steps.
	activity:   bool,
}

init :: proc(s: ^Undo_Stack) {
	s.items = make([dynamic]Entry)
	s.txn_stack = make([dynamic]Group_Command)
	s.recording = true
}

clear :: proc(s: ^Undo_Stack) {
	if s == nil do return
	for &e in s.items {
		_entry_destroy(&e)
	}
	builtin.clear(&s.items)
	for &g in s.txn_stack {
		_group_destroy(&g)
	}
	builtin.clear(&s.txn_stack)
	s.top = 0
	s.activity = true
}

destroy :: proc(s: ^Undo_Stack) {
	if s == nil do return
	clear(s)
	delete(s.items)
	delete(s.txn_stack)
	s.items = {}
	s.txn_stack = {}
	inspector_shutdown()
}

set_recording :: proc(s: ^Undo_Stack, on: bool) {
	s.recording = on
}

is_applying :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.applying
}

get :: proc() -> ^Undo_Stack {
	uc := engine.ctx_get()
	if uc == nil do return nil
	return (^Undo_Stack)(uc.undo)
}

install :: proc(s: ^Undo_Stack) {
	uc := engine.ctx_get()
	if uc == nil do return
	uc.undo = rawptr(s)
}

push :: proc(s: ^Undo_Stack, cmd: Command, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return
	s.activity = true

	if len(s.txn_stack) > 0 {
		top_txn := &s.txn_stack[len(s.txn_stack) - 1]
		append(&top_txn.subs, cmd)
		return
	}

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}

	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}

	effective_label := label
	if effective_label == "" {
		effective_label = default_label(cmd)
	}
	append(&s.items, Entry{label = strings.clone(effective_label), cmd = cmd})
	s.top = len(s.items)
}

jump_to :: proc(s: ^Undo_Stack, target_top: int) -> bool {
	if s == nil do return false
	if target_top < 0 || target_top > len(s.items) do return false
	for s.top > target_top {
		if !apply_undo(s) do return false
	}
	for s.top < target_top {
		if !apply_redo(s) do return false
	}
	return true
}

default_label :: proc(cmd: Command) -> string {
	switch v in cmd {
	case Value_Command:
		switch v.target.kind {
		case .None:   return "Edit Value"
		case .Pooled: return v.target.handle.type_key == .Transform ? "Edit Transform" : "Edit Component"
		case .Raw:    return "Edit"
		case .Asset:  return "Edit Asset"
		}
		return "Edit Value"
	case Dropdown_Revert_Command:
		return "Revert Override"
	case Record_Override_Command:
		// Never the label of a step on its own — it always rides the value
		// command's group, which supplies the label.
		return "Prefab Override"
	case Structural_Command:
		switch sv in v {
		case Reparent_Command:           return "Reparent"
		case Create_Subtree_Command:     return "Create"
		case Delete_Subtree_Command:     return "Delete"
		case Add_Component_Command:      return "Add Component"
		case Remove_Component_Command:   return "Remove Component"
		case Reorder_Components_Command: return "Reorder Components"
		case Remove_Unknown_Component_Command: return "Remove Missing Component"
		}
		return "Structural"
	case Group_Command:
		return "Group"
	case Selection_Command:
		return "Select"
	}
	return ""
}

begin_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return
	append(&s.txn_stack, Group_Command{subs = make([dynamic]Command)})
}

abort_group_command :: proc(s: ^Undo_Stack) {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)
	_group_destroy(&grp)
}

end_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)

	if len(grp.subs) == 0 {
		delete(grp.subs)
		return
	}

	if len(s.txn_stack) > 0 {
		outer := &s.txn_stack[len(s.txn_stack) - 1]
		append(&outer.subs, Command(grp))
		return
	}

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}
	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}
	// Clone like push() does — _entry_destroy deletes the label, and group
	// labels are usually string literals.
	append(&s.items, Entry{label = strings.clone(label), cmd = Command(grp)})
	s.top = len(s.items)
	s.activity = true
}

can_undo :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.top > 0
}

entries :: proc(s: ^Undo_Stack) -> []Entry {
	if s == nil do return nil
	return s.items[:]
}

top_index :: proc(s: ^Undo_Stack) -> int {
	if s == nil do return 0
	return s.top
}

can_redo :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.top < len(s.items)
}

apply_undo :: proc(s: ^Undo_Stack) -> bool {
	if !can_undo(s) do return false
	s.activity = true
	s.applying = true
	defer s.applying = false
	s.top -= 1
	cmd := &s.items[s.top].cmd
	_revert_command(cmd)
	return true
}

apply_redo :: proc(s: ^Undo_Stack) -> bool {
	if !can_redo(s) do return false
	s.activity = true
	s.applying = true
	defer s.applying = false
	cmd := &s.items[s.top].cmd
	_apply_command(cmd)
	s.top += 1
	return true
}

@(private)
_apply_command :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		_value_apply(v, v.new_json)
	case Structural_Command:
		_structural_apply(v)
	case Group_Command:
		for i in 0 ..< len(v.subs) {
			_apply_command(&v.subs[i])
		}
	case Selection_Command:
		_selection_apply(v.after)
	case Record_Override_Command:
		// REDO: put the record back the way the original action left it.
		switch v.op {
		case .Created:
			// The value sub-command restored the edited value, so the record
			// comes back with it.
			_override_record_reapply(v)
		case .Removed:
			_override_record_rerevert(v)
		case .Comp_Removed:
			_comp_removal_record(v)
		case .Comp_Added:
			_comp_addition_record(v)
		case .Obj_Removed:
			_obj_removal_record(v)
		}
	case Dropdown_Revert_Command:
		_dropdown_revert_apply(v) // REDO: drop the record again
	}
}

@(private)
_revert_command :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		_value_apply(v, v.old_json)
	case Structural_Command:
		_structural_revert(v)
	case Group_Command:
		for i := len(v.subs) - 1; i >= 0; i -= 1 {
			_revert_command(&v.subs[i])
		}
	case Selection_Command:
		_selection_apply(v.before)
	case Record_Override_Command:
		// UNDO: invert whatever the action did to the record.
		switch v.op {
		case .Created:
			// Drop the override this edit introduced — the paired
			// Value_Command puts the old value back, so leaving the record
			// would mark the field overridden while it holds its baseline.
			_override_record_remove(v)
		case .Removed:
			// Undo of a Revert: the value command restores the overridden
			// value, so the record must come back too.
			_override_record_restore(v)
		case .Comp_Removed:
			// The paired Remove_Component_Command re-created the component;
			// retract the removal so a resolve keeps it.
			_comp_removal_retract(v)
		case .Comp_Added:
			// The paired Add_Component_Command destroyed the component;
			// retract the addition record with it.
			_comp_addition_retract(v)
		case .Obj_Removed:
			// The paired Delete_Subtree_Command restored the subtree; retract
			// the suppression so a resolve keeps it.
			_obj_removal_retract(v)
		}
	case Dropdown_Revert_Command:
		_dropdown_revert_undo(v)
	}
}

@(private)
_override_host :: proc(v: Record_Override_Command) -> (^engine.Scene, engine.Transform_Handle, bool) {
	s := resolve_scene(v.scene)
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
	s := resolve_scene(v.scene)
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
// verbatim (a revert can clear several paths under one field); a structural row
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
_command_destroy_dropdown_revert :: proc(v: ^Dropdown_Revert_Command) {
	delete(v.property_path)
	discard_override_removal(v.removed)
	v.removed = nil
	engine.nested_override_snapshot_destroy(&v.snapshot)
}

// Records a dropdown revert as its own undo step. `snap` and `removed` transfer
// ownership — on a stack that is not recording they are freed here.
record_dropdown_revert :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	kind: engine.Override_Entry_Kind,
	target: engine.PPtr,
	property_path: string,
	removed: []Removed_Override,
	snap: engine.Override_Snapshot,
) {
	snap := snap
	u := get()
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if u == nil || !u.recording || u.applying || ht == nil {
		discard_override_removal(removed)
		engine.nested_override_snapshot_destroy(&snap)
		return
	}
	push(u, Dropdown_Revert_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		kind          = kind,
		target        = target,
		property_path = strings.clone(property_path),
		removed       = removed,
		snapshot      = snap,
	}, "Revert Override")
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

// --- Structural component-edit bookkeeping ------------------------------------
// The live component is handled by the paired Add_/Remove_Component_Command;
// these only add or retract the NestedScene record, so the edit survives the
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

@(private)
_entry_destroy :: proc(e: ^Entry) {
	delete(e.label)
	_command_destroy(&e.cmd)
}

@(private)
_command_destroy :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		vc := v
		delete(vc.old_json)
		delete(vc.new_json)
	case Structural_Command:
		sc := v
		_structural_destroy(&sc)
	case Group_Command:
		gc := v
		_group_destroy(&gc)
	case Selection_Command:
		sel := v
		selection_state_destroy(&sel.before)
		selection_state_destroy(&sel.after)
	case Record_Override_Command:
		roc := v
		_command_destroy_override(&roc)
	case Dropdown_Revert_Command:
		drc := v
		_command_destroy_dropdown_revert(&drc)
	}
}

// Attaches "this edit created a prefab override" to the undo step that just
// recorded the value change, so undoing the edit also removes the record (and
// redo puts it back). Call right after the engine reports created == true.
//
// Field edits push their Value_Command standalone rather than inside a
// transaction, so this FOLDS the top entry and the override bookkeeping into
// one Group_Command — the two must be inseparable, or a value undo would
// strand a record marking the field overridden while it holds its baseline.
record_override_created :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	target_lid: engine.Local_ID,
	property_path: string,
) {
	u := get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return

	_override_cmd_attach(u, Record_Override_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		target_lid    = target_lid,
		property_path = strings.clone(property_path),
		op            = .Created,
	})
}

// Attaches "this edit removed a prefab-instance component" to the undo step
// that just recorded the component removal, so undo retracts the removal record
// along with re-creating the component.
record_component_removed_on_instance :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	comp_lid: engine.Local_ID,
) {
	u := get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, Record_Override_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		target_lid    = comp_lid,
		op            = .Comp_Removed,
	})
}

// Attaches "this edit added a component to a prefab instance" to the undo step
// that just recorded the component add. `type_guid`/`comp_json` let redo rebuild
// the NestedScene record for the re-created component.
record_component_added_on_instance :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	owner_lid: engine.Local_ID,
	comp_lid: engine.Local_ID,
	type_guid: string,
	comp_json: string,
) {
	u := get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, Record_Override_Command{
		scene          = scene_ref(s),
		host_local_id  = ht.local_id,
		target_lid     = comp_lid,
		op             = .Comp_Added,
		owner_lid      = owner_lid,
		comp_type_guid = strings.clone(type_guid),
		comp_json      = strings.clone(comp_json),
	})
}

// Attaches "this delete removed a prefab-instance object" to the undo step
// that just recorded the subtree deletion, so undo retracts the suppression
// along with restoring the subtree.
record_object_removed_on_instance :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	obj_lid: engine.Local_ID,
) {
	u := get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, Record_Override_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		target_lid    = obj_lid,
		op            = .Obj_Removed,
	})
}

// Copies the override entries a Revert is about to delete. Call BEFORE
// nested_scene_revert_override — afterwards they are gone. Hand the result to
// record_override_removed once the Revert's own undo step has committed.
// Owned: record_override_removed takes it over, or discard_override_removal
// frees it.
override_removal_snapshot :: proc(
	ns: ^engine.NestedScene,
	target: engine.PPtr,
	property_path: string,
) -> []Removed_Override {
	targets, paths, values := engine.nested_scene_overrides_covered_by(ns, target, property_path)
	if len(paths) == 0 do return nil
	out := make([]Removed_Override, len(paths))
	for i in 0 ..< len(paths) {
		out[i] = Removed_Override{
			target        = targets[i],
			property_path = strings.clone(paths[i]),
			value_json    = slice_clone_bytes(values[i]),
		}
	}
	return out
}

discard_override_removal :: proc(snap: []Removed_Override) {
	for r in snap {
		delete(r.property_path)
		delete(r.value_json)
	}
	if snap != nil do delete(snap)
}

// Attaches a snapshot of Revert-deleted override entries to the undo step that
// just recorded the Revert's value change, so undoing the Revert restores both
// the value (its own Value_Command) and the record.
record_override_removed :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	target_lid: engine.Local_ID,
	property_path: string,
	snap: []Removed_Override,
) {
	if len(snap) == 0 do return
	u := get()
	if u == nil || !u.recording || u.applying {
		discard_override_removal(snap)
		return
	}
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil {
		discard_override_removal(snap)
		return
	}

	_override_cmd_attach(u, Record_Override_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		target_lid    = target_lid,
		property_path = strings.clone(property_path),
		op            = .Removed,
		removed       = snap,
	})
}

@(private)
slice_clone_bytes :: proc(src: []byte) -> []byte {
	out := make([]byte, len(src))
	copy(out, src)
	return out
}

// Attaches override bookkeeping to the CURRENT undo step. Value edits and the
// Revert menu both push their Value_Command standalone rather than inside a
// transaction, so this FOLDS the top entry and the bookkeeping into one
// Group_Command — the two must be inseparable, or a value undo would leave the
// record disagreeing with the value it describes.
@(private)
_override_cmd_attach :: proc(u: ^Undo_Stack, cmd: Record_Override_Command) {
	cmd := cmd
	// Inside a transaction (multi-field edits, gizmo drags): just join it.
	if len(u.txn_stack) > 0 {
		g := &u.txn_stack[len(u.txn_stack) - 1]
		append(&g.subs, Command(cmd))
		return
	}

	// Standalone: fold with the value entry that was pushed a moment ago.
	if u.top <= 0 || u.top > len(u.items) {
		c := cmd
		_command_destroy_override(&c)
		return
	}
	e := &u.items[u.top - 1]
	if grp, is_group := &e.cmd.(Group_Command); is_group {
		append(&grp.subs, Command(cmd))
		return
	}
	subs := make([dynamic]Command)
	append(&subs, e.cmd)
	append(&subs, Command(cmd))
	e.cmd = Group_Command{subs = subs}
}

@(private)
_command_destroy_override :: proc(v: ^Record_Override_Command) {
	delete(v.property_path)
	delete(v.comp_type_guid)
	delete(v.comp_json)
	for r in v.removed {
		delete(r.property_path)
		delete(r.value_json)
	}
	if v.removed != nil do delete(v.removed)
}

@(private)
_group_destroy :: proc(g: ^Group_Command) {
	for i in 0 ..< len(g.subs) {
		_command_destroy(&g.subs[i])
	}
	delete(g.subs)
}

@(private)
_structural_destroy :: proc(sc: ^Structural_Command) {
	switch v in sc {
	case Reparent_Command:
	case Create_Subtree_Command:
		if v.payload != nil do delete(v.payload)
	case Delete_Subtree_Command:
		if v.payload != nil do delete(v.payload)
	case Add_Component_Command:
		if v.payload != nil do delete(v.payload)
	case Remove_Component_Command:
		if v.payload != nil do delete(v.payload)
	case Reorder_Components_Command:
	case Remove_Unknown_Component_Command:
		if v.payload != nil do delete(v.payload)
	}
}

resolve_target_ptr :: proc(t: Property_Target) -> rawptr {
	switch t.kind {
	case .None:
		return nil
	case .Raw:
		if t.raw_ptr == nil do return nil
		return rawptr(uintptr(t.raw_ptr) + uintptr(t.offset))
	case .Pooled:
		base, _, ok := resolve_pooled_base(t)
		if !ok do return nil
		return rawptr(uintptr(base) + uintptr(t.offset))
	case .Asset:
		return nil // applied through the asset hook, never via pointer
	}
	return nil
}

resolve_pooled_base :: proc(t: Property_Target) -> (rawptr, engine.Handle, bool) {
	if t.kind != .Pooled do return nil, {}, false
	w := engine.ctx_world()
	if w == nil do return nil, {}, false
	h := t.handle
	if !engine.world_pool_valid(w, h) {
		sc := resolve_scene(t.scene)
		if sc == nil || t.local_id == 0 do return nil, {}, false
		resolved: engine.Handle
		ok: bool
		if h.type_key == .Transform {
			resolved, ok = scene_find_transform_by_local_id(sc, t.local_id)
		} else {
			resolved, ok = scene_find_component_by_local_id(sc, t.local_id)
		}
		if !ok do return nil, {}, false
		h = resolved
	}
	base := engine.world_pool_get(w, h)
	if base == nil do return nil, h, false
	return base, h, true
}

resolve_component_base :: proc(t: Property_Target) -> (rawptr, engine.Handle, bool) {
	if t.kind != .Pooled || t.handle.type_key == .Transform do return nil, {}, false
	return resolve_pooled_base(t)
}

make_pooled_target :: proc(h: engine.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	w := engine.ctx_world()
	scene: ^engine.Scene
	lid: engine.Local_ID
	if h.type_key == .Transform {
		if t := engine.pool_get(&w.transforms, h); t != nil {
			scene = t.scene
			lid = t.local_id
		}
	} else {
		if base := engine.world_pool_get(w, h); base != nil {
			cbase := cast(^engine.CompData)base
			lid = cbase.local_id
			if t := engine.pool_get(&w.transforms, engine.Handle(cbase.owner)); t != nil {
				scene = t.scene
			}
		}
	}
	return Property_Target{
		kind = .Pooled,
		scene = scene_ref(scene),
		local_id = lid,
		handle = h,
		offset = u32(offset),
		type_id = tid,
	}
}

make_transform_target :: proc(tH: engine.Transform_Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(engine.Handle(tH), offset, tid)
}

make_component_target :: proc(comp_handle: engine.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(comp_handle, offset, tid)
}

make_raw_target :: proc(ptr: rawptr, offset: uintptr, tid: typeid) -> Property_Target {
	return Property_Target{
		kind = .Raw,
		raw_ptr = ptr,
		offset = u32(offset),
		type_id = tid,
	}
}

capture_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	if ptr == nil || tid == nil do return nil
	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	data, err := json.marshal(any{ptr, tid}, opts)
	if err != nil {
		log.error(fmt.tprintf("undo: marshal failed for %v: %v", tid, err))
		return nil
	}
	return data
}

push_value :: proc(s: ^Undo_Stack, t: Property_Target, old_json, new_json: []byte, label := "") {
	if s == nil do return
	if !s.recording || s.applying {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if old_json == nil || new_json == nil {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if slice.equal(old_json, new_json) {
		delete(old_json)
		delete(new_json)
		return
	}
	cmd: Value_Command = {target = t, old_json = old_json, new_json = new_json}
	push(s, Command(cmd), label)
}

@(private)
_value_apply :: proc(vc: Value_Command, json_bytes: []byte) {
	if vc.target.kind == .Asset {
		if _asset_apply_hook == nil {
			log.error("undo: no asset apply hook installed (inspector init missing?)")
			return
		}
		if !_asset_apply_hook(vc.target.asset_guid, json_bytes) {
			log.error(fmt.tprintf("undo: asset apply failed (guid=%v)", vc.target.asset_guid))
		}
		return
	}
	ptr := resolve_target_ptr(vc.target)
	if ptr == nil {
		log.error(fmt.tprintf("undo: failed to resolve target for value command (tid=%v)", vc.target.type_id))
		return
	}
	if !write_json_value(ptr, vc.target.type_id, json_bytes, resolve_scene(vc.target.scene)) {
		return
	}

	if vc.target.kind == .Pooled && vc.target.handle.type_key != .Transform {
		if base, h, ok := resolve_pooled_base(vc.target); ok {
			engine.component_on_validate(h.type_key, base)
		}
	}
}

// Writes a captured value (capture_json output) into a live field, replacing
// whatever it holds. THE way to assign a field of arbitrary type: it releases
// the old value's heap memory, unmarshals a FRESH copy of the payload — so the
// destination shares no backing storage with the source — and rebinds any
// reference handles inside it.
//
// `s` is the scene the field lives in, for that rebinding. A nil scene skips it,
// which is right for values that hold no references.
//
// Used by undo to apply a Value_Command, and by multi-edit to copy one committed
// field onto the rest of a selection. Both need identical semantics, and having
// one implementation is what stops them drifting.
write_json_value :: proc(ptr: rawptr, tid: typeid, json_bytes: []byte, s: ^engine.Scene) -> bool {
	if ptr == nil || tid == nil || json_bytes == nil do return false
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(tid)
	if !ok {
		log.error(fmt.tprintf("undo: no pointer typeid registered for %v — call engine.register_pointer_type during init", tid))
		return false
	}

	_cleanup_before_unmarshal(ptr, tid)

	target_ptr := ptr
	target_any := any{data = &target_ptr, id = ptr_tid}
	if err := json.unmarshal_any(json_bytes, target_any, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
		log.error(fmt.tprintf("undo: unmarshal failed (tid=%v): %v", tid, err))
		return false
	}

	// The payload carries only PPtr data — Handle fields are json:"-", so
	// unmarshal leaves whatever handle the pre-apply value had (zero after a
	// load, RESOLVED after a prior undo). Authoritative mode derives handles
	// entirely from the payload: bound when the lid resolves, cleared when
	// the payload says none.
	if s != nil {
		engine._resolve_refs_in_value(ptr, type_info_of(tid), s, nil, false, true)
	}
	return true
}

@(private)
_cleanup_before_unmarshal :: proc(ptr: rawptr, tid: typeid) {
	if ptr == nil do return
	if tid == typeid_of(string) {
		s := cast(^string)ptr
		if len(s^) > 0 do delete(s^)
		s^ = ""
		return
	}
	if key, ok := engine.get_type_key_by_typeid(tid); ok {
		engine.type_cleanup(key, ptr)
	}
}

scene_find_transform_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	tH, ok := engine.scene_find_outer_transform_local_id(s, id)
	if !ok do return {}, false
	return engine.Handle(tH), true
}

scene_find_component_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	it := engine.pool_iterator(&w.transforms)
	for t, _ in engine.pool_next(&it) {
		if t.scene != s do continue
		if t.nested_owned do continue
		for c in t.components {
			if c.local_id == id && c.handle.type_key != engine.INVALID_TYPE_KEY {
				raw := engine.world_pool_get(w, c.handle)
				if raw != nil {
					base := cast(^engine.CompData)raw
					if base.nested_owned do continue
				}
				return c.handle, true
			}
		}
	}
	return {}, false
}

@(private)
_structural_apply :: proc(sc: Structural_Command) {
	switch v in sc {
	case Reparent_Command:
		_do_reparent(resolve_scene(v.scene), v.node_local_id, v.new_parent_local_id, v.new_index)
	case Create_Subtree_Command:
		_do_create_subtree(v)
	case Delete_Subtree_Command:
		_do_delete_subtree(v)
	case Add_Component_Command:
		_do_add_component(v)
	case Remove_Component_Command:
		_do_remove_component(v)
	case Reorder_Components_Command:
		_do_reorder_components(resolve_scene(v.scene), v.owner_local_id, v.old_index, v.new_index)
	case Remove_Unknown_Component_Command:
		_do_remove_unknown_component(v)
	}
}

@(private)
_structural_revert :: proc(sc: Structural_Command) {
	switch v in sc {
	case Reparent_Command:
		_do_reparent(resolve_scene(v.scene), v.node_local_id, v.old_parent_local_id, v.old_index)
	case Create_Subtree_Command:
		_undo_create_subtree(v)
	case Delete_Subtree_Command:
		_undo_delete_subtree(v)
	case Add_Component_Command:
		_undo_add_component(v)
	case Remove_Component_Command:
		_undo_remove_component(v)
	case Reorder_Components_Command:
		_do_reorder_components(resolve_scene(v.scene), v.owner_local_id, v.new_index, v.old_index)
	case Remove_Unknown_Component_Command:
		_undo_remove_unknown_component(v)
	}
}

@(private)
_do_reparent :: proc(s: ^engine.Scene, node_id: engine.Local_ID, new_parent_id: engine.Local_ID, new_index: int) {
	node_h, ok := scene_find_transform_by_local_id(s, node_id)
	if !ok do return
	parent_h: engine.Handle
	if new_parent_id != 0 {
		p, pok := scene_find_transform_by_local_id(s, new_parent_id)
		if !pok do return
		parent_h = p
	} else {
		if s == nil do return
		parent_h = s.root.handle
	}
	engine.transform_set_parent(engine.Transform_Handle(node_h), engine.Transform_Handle(parent_h), new_index)
}

@(private)
_do_create_subtree :: proc(v: Create_Subtree_Command) {
	parent_h, ok := _find_transform_for_undo(resolve_scene(v.scene), v.parent_local_id)
	if !ok do return
	_paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
}

@(private)
_undo_create_subtree :: proc(v: Create_Subtree_Command) {
	node_h, ok := _find_transform_for_undo(resolve_scene(v.scene), v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

@(private)
_do_delete_subtree :: proc(v: Delete_Subtree_Command) {
	node_h, ok := _find_transform_for_undo(resolve_scene(v.scene), v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

// Transform lookup for undo/redo of structural edits. PREFAB CONTENT is not in
// the scene bimap — composed instance lids belong to the instance, not the host
// — and neither is a host object created under prefab content, so the bimap
// lookup alone silently no-ops every nested structural redo. Falls back to a
// live scan of the scene's transforms.
@(private)
_find_transform_for_undo :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if h, ok := scene_find_transform_by_local_id(s, id); ok do return h, true
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.local_id != id do continue
		h := h
		h.type_key = .Transform
		return h, true
	}
	return {}, false
}

@(private)
_undo_delete_subtree :: proc(v: Delete_Subtree_Command) {
	parent_h, ok := _find_transform_for_undo(resolve_scene(v.scene), v.parent_local_id)
	if !ok do return
	root := _paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
	if v.nested_owned && root != {} {
		engine.transform_mark_subtree_nested_owned(root)
	}
}

@(private)
_paste_subtree_preserve_ids :: proc(payload: []byte, parent: engine.Transform_Handle, sibling_index: int) -> engine.Transform_Handle {
	if payload == nil || len(payload) == 0 do return {}
	sf: engine.SceneFile
	if err := json.unmarshal(payload, &sf); err != nil {
		log.error(fmt.tprintf("undo: unmarshal subtree failed: %v", err))
		return {}
	}
	defer engine.scene_file_destroy(&sf)

	w := engine.ctx_world()
	parent_scene: ^engine.Scene
	if p := engine.pool_get(&w.transforms, engine.Handle(parent)); p != nil {
		parent_scene = p.scene
	}

	root_tH := engine._scene_load_as_child(&sf, parent, parent_scene)
	if root_tH == {} do return {}

	p := engine.pool_get(&w.transforms, engine.Handle(parent))
	if p != nil && sibling_index >= 0 {
		current_idx := -1
		for i in 0 ..< len(p.children) {
			if p.children[i].handle == engine.Handle(root_tH) {
				current_idx = i
				break
			}
		}
		if current_idx >= 0 && current_idx != sibling_index {
			entry := p.children[current_idx]
			ordered_remove(&p.children, current_idx)
			idx := sibling_index
			if idx > len(p.children) do idx = len(p.children)
			inject_at(&p.children, idx, entry)
		}
	}

	if engine.application_is_editor() {
		engine._scene_resolve_nested_in_subtree(root_tH)
	}

	// Components OUTSIDE the restored subtree may reference INTO it (a Tank on
	// the root pointing at a deleted-then-restored Turret) — their handles are
	// dead and only a scene-wide rebind reaches them. The loader re-registered
	// the restored lids (dead-entry repair), so the sweep binds them live.
	engine.scene_rebind_unbound_refs(parent_scene)

	return root_tH
}

@(private)
_do_add_component :: proc(v: Add_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(resolve_scene(v.scene), v.owner_local_id)
	if !ok do return
	tH := engine.Transform_Handle(owner_h)

	owned, ptr := engine.transform_add_comp(tH, v.type_key)
	if ptr == nil do return

	if v.payload != nil && len(v.payload) > 0 {
		tid := engine.get_typeid_by_type_key(v.type_key)
		ptr_tid, ptr_ok := engine.get_pointer_typeid_by_typeid(tid)
		if ptr_ok {
			target_ptr := ptr
			if err := json.unmarshal_any(v.payload, any{&target_ptr, ptr_tid}, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
				log.error(fmt.tprintf("undo: unmarshal component failed: %v", err))
			}
			base := cast(^engine.CompData)ptr
			base.owner = tH
			base.local_id = v.comp_local_id
			// Handles are json:"-" — rebind the payload's Refs (see _value_apply).
			if s := resolve_scene(v.scene); s != nil {
				engine._resolve_refs_in_value(ptr, type_info_of(tid), s, nil, false, true)
			}
			engine.component_on_validate(v.type_key, ptr)
		}
	}

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
	if t != nil && v.list_index >= 0 && v.list_index < len(t.components) {
		last := len(t.components) - 1
		if last != v.list_index {
			entry := t.components[last]
			ordered_remove(&t.components, last)
			inject_at(&t.components, v.list_index, entry)
		}
	}

	base := cast(^engine.CompData)ptr
	base.local_id = v.comp_local_id
	// transform_add_comp minted (and registered) a throwaway lid — the restored
	// component answers to its RECORDED lid, so point the live index at it and
	// rebind any refs that dangled while the component was gone.
	if s := resolve_scene(v.scene); s != nil {
		engine.bimap_insert(&s.local_ids, v.comp_local_id, owned.handle)
		engine.scene_rebind_unbound_refs(s)
	}
	if t != nil {
		for i in 0 ..< len(t.components) {
			if t.components[i].handle == owned.handle {
				t.components[i].local_id = v.comp_local_id
				break
			}
		}
	}
}

@(private)
_undo_add_component :: proc(v: Add_Component_Command) {
	sc := resolve_scene(v.scene)
	comp_h, ok := scene_find_component_by_local_id(sc, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(sc, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

@(private)
_do_remove_component :: proc(v: Remove_Component_Command) {
	sc := resolve_scene(v.scene)
	comp_h, ok := scene_find_component_by_local_id(sc, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(sc, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

@(private)
_undo_remove_component :: proc(v: Remove_Component_Command) {
	add: Add_Component_Command = {
		scene = v.scene,
		owner_local_id = v.owner_local_id,
		type_key = v.type_key,
		comp_local_id = v.comp_local_id,
		payload = v.payload,
		list_index = v.list_index,
	}
	_do_add_component(add)
}

@(private)
_do_remove_unknown_component :: proc(v: Remove_Unknown_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(resolve_scene(v.scene), v.owner_local_id)
	if !ok do return
	engine.transform_remove_unknown_comp(engine.Transform_Handle(owner_h), v.comp_local_id)
}

@(private)
_undo_remove_unknown_component :: proc(v: Remove_Unknown_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(resolve_scene(v.scene), v.owner_local_id)
	if !ok do return
	val, perr := json.parse(v.payload, .JSON, true, context.temp_allocator)
	if perr != nil do return
	// transform_restore_unknown_comp clones `val` — the temp parse dies with the frame.
	engine.transform_restore_unknown_comp(engine.Transform_Handle(owner_h), v.comp_local_id, val, v.list_index)
}

@(private)
_do_reorder_components :: proc(s: ^engine.Scene, owner_local_id: engine.Local_ID, from, to: int) {
	owner_h, ok := scene_find_transform_by_local_id(s, owner_local_id)
	if !ok do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, owner_h)
	if t == nil do return
	if from < 0 || from >= len(t.components) do return
	if to < 0 || to >= len(t.components) do return
	if from == to do return
	entry := t.components[from]
	ordered_remove(&t.components, from)
	inject_at(&t.components, to, entry)
}

capture_transform_subtree :: proc(tH: engine.Transform_Handle) -> []byte {
	return engine.scene_copy_subtree(tH)
}

capture_component_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	return capture_json(ptr, tid)
}

// --- Editor hooks -------------------------------------------------------------
// The undo package sits below the editor (it may not import selection or the
// inspector), so restoration of editor-level state goes through hooks
// installed at startup. Unset hooks degrade to no-ops (tests, headless).

@(private) _selection_capture_hook: proc() -> Selection_State
@(private) _selection_apply_hook:   proc(state: Selection_State)
@(private) _asset_apply_hook:       proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool

set_selection_hooks :: proc(capture: proc() -> Selection_State, apply: proc(state: Selection_State)) {
	_selection_capture_hook = capture
	_selection_apply_hook = apply
}

// cb replaces the whole asset document identified by guid with the given
// JSON payload (installed by the project inspector's doc registry).
set_asset_apply :: proc(cb: proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool) {
	_asset_apply_hook = cb
}

@(private)
_selection_apply :: proc(state: Selection_State) {
	if _selection_apply_hook != nil do _selection_apply_hook(state)
}

make_asset_target :: proc(guid: engine.Asset_GUID, tid: typeid) -> Property_Target {
	return Property_Target{kind = .Asset, asset_guid = guid, type_id = tid}
}

// --- Selection state helpers ----------------------------------------------------

selection_state_destroy :: proc(st: ^Selection_State) {
	if st.scene != nil do delete(st.scene)
	for p in st.proj do delete(p)
	if st.proj != nil do delete(st.proj)
	st^ = {}
}

selection_state_equal :: proc(a, b: Selection_State) -> bool {
	if len(a.scene) != len(b.scene) || len(a.proj) != len(b.proj) do return false
	for it, i in a.scene {
		if it != b.scene[i] do return false
	}
	for p, i in a.proj {
		if p != b.proj[i] do return false
	}
	return true
}

// Pushes one selection step. Takes OWNERSHIP of both states on every path
// (pushed, skipped as equal, or dropped because recording is off).
push_selection :: proc(s: ^Undo_Stack, before, after: Selection_State, label := "") {
	b := before
	a := after
	if s == nil || !s.recording || s.applying || selection_state_equal(b, a) {
		selection_state_destroy(&b)
		selection_state_destroy(&a)
		return
	}
	push(s, Command(Selection_Command{before = b, after = a}), label)
}

// For structural groups that consume the selection (delete/duplicate): push a
// selection step whose `before` is the current selection and `after` is empty.
// Push it FIRST inside the group, so group revert (which walks subs in
// reverse) restores the selection only after the objects are back.
record_selection_snapshot :: proc() {
	s := get()
	if s == nil || !s.recording || s.applying do return
	if _selection_capture_hook == nil do return
	before := _selection_capture_hook()
	if len(before.scene) == 0 && len(before.proj) == 0 {
		selection_state_destroy(&before)
		return
	}
	push(s, Command(Selection_Command{before = before}))
}

// True once after any stack mutation since the last call. The editor's
// per-frame selection tracker uses this to re-baseline instead of recording.
activity_consume :: proc(s: ^Undo_Stack) -> bool {
	if s == nil do return false
	res := s.activity
	s.activity = false
	return res
}

// --- Purge ----------------------------------------------------------------------
// Scene load/unload no longer wipes the whole history: only entries that
// reference the affected scene(s) are dropped. Asset edits and pure project
// selection steps survive scene navigation.

@(private)
_scene_ref_matches :: proc(r: Scene_Ref, ptr: ^engine.Scene, guid: engine.Asset_GUID, any_scene: bool) -> bool {
	if r.ptr == nil && engine.asset_guid_is_empty(r.guid) do return false
	if any_scene do return true
	if r.ptr != nil && r.ptr == ptr do return true
	if !engine.asset_guid_is_empty(guid) && r.guid == guid do return true
	return false
}

@(private)
_selection_state_refs_scene :: proc(st: Selection_State, ptr: ^engine.Scene, guid: engine.Asset_GUID, any_scene: bool) -> bool {
	for it in st.scene {
		if _scene_ref_matches(it.scene, ptr, guid, any_scene) do return true
	}
	return false
}

@(private)
_command_refs_scene :: proc(cmd: ^Command, ptr: ^engine.Scene, guid: engine.Asset_GUID, any_scene: bool) -> bool {
	switch v in cmd {
	case Value_Command:
		if v.target.kind != .Pooled do return false
		return _scene_ref_matches(v.target.scene, ptr, guid, any_scene)
	case Structural_Command:
		r: Scene_Ref
		switch sv in v {
		case Reparent_Command:           r = sv.scene
		case Create_Subtree_Command:     r = sv.scene
		case Delete_Subtree_Command:     r = sv.scene
		case Add_Component_Command:      r = sv.scene
		case Remove_Component_Command:   r = sv.scene
		case Reorder_Components_Command: r = sv.scene
		case Remove_Unknown_Component_Command: r = sv.scene
		}
		return _scene_ref_matches(r, ptr, guid, any_scene)
	case Dropdown_Revert_Command:
		return _scene_ref_matches(v.scene, ptr, guid, any_scene)
	case Group_Command:
		for i in 0 ..< len(v.subs) {
			if _command_refs_scene(&v.subs[i], ptr, guid, any_scene) do return true
		}
		return false
	case Record_Override_Command:
		return _scene_ref_matches(v.scene, ptr, guid, any_scene)
	case Selection_Command:
		return _selection_state_refs_scene(v.before, ptr, guid, any_scene) ||
			_selection_state_refs_scene(v.after, ptr, guid, any_scene)
	}
	return false
}

@(private)
_purge :: proc(s: ^Undo_Stack, ptr: ^engine.Scene, guid: engine.Asset_GUID, any_scene: bool) {
	if s == nil do return
	for i := len(s.items) - 1; i >= 0; i -= 1 {
		if !_command_refs_scene(&s.items[i].cmd, ptr, guid, any_scene) do continue
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
		if i < s.top do s.top -= 1
	}
	s.activity = true
}

// Drop entries that reference this scene. Call BEFORE unloading, while the
// pointer is still valid.
purge_scene :: proc(s: ^Undo_Stack, scene: ^engine.Scene) {
	if scene == nil do return
	_purge(s, scene, scene.asset_guid, false)
}

// Drop entries that reference ANY scene (single-scene loads unload everything);
// asset edits and project-only selection steps survive.
purge_scenes :: proc(s: ^Undo_Stack) {
	_purge(s, nil, {}, true)
}
