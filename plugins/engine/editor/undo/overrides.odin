package scene_undo

// Records prefab override edits on the undo stack: the record half of a live
// edit on a prefab instance, a Revert, a row reverted from the Overrides
// dropdown, and a Prefab Apply.

import "core:slice"
import "core:strings"
import shell "moonhug:editor/undo"
import engine "moonhug:packages/engine"
import "moonhug:packages/engine/editor/undo_ops"

discard_override_removal :: undo_ops.discard_override_removal

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
	u := shell.get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return

	_override_cmd_attach(u, undo_ops.Record_Override_Command{
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
	u := shell.get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, undo_ops.Record_Override_Command{
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
	u := shell.get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, undo_ops.Record_Override_Command{
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
	u := shell.get()
	if u == nil || !u.recording || u.applying do return
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	_override_cmd_attach(u, undo_ops.Record_Override_Command{
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
) -> []undo_ops.Removed_Override {
	targets, paths, values := engine.nested_scene_overrides_covered_by(ns, target, property_path)
	if len(paths) == 0 do return nil
	out := make([]undo_ops.Removed_Override, len(paths))
	for i in 0 ..< len(paths) {
		out[i] = undo_ops.Removed_Override{
			target        = targets[i],
			property_path = strings.clone(paths[i]),
			value_json    = slice.clone(values[i]),
		}
	}
	return out
}

// Attaches a snapshot of Revert-deleted override entries to the undo step that
// just recorded the Revert's value change, so undoing the Revert restores both
// the value (its own Value_Command) and the record.
record_override_removed :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	target_lid: engine.Local_ID,
	property_path: string,
	snap: []undo_ops.Removed_Override,
) {
	if len(snap) == 0 do return
	u := shell.get()
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

	_override_cmd_attach(u, undo_ops.Record_Override_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		target_lid    = target_lid,
		property_path = strings.clone(property_path),
		op            = .Removed,
		removed       = snap,
	})
}

// Records a dropdown revert as its own undo step. `snap` and `removed` transfer
// ownership — on a stack that is not recording they are freed here.
record_dropdown_revert :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	kind: engine.Override_Entry_Kind,
	target: engine.PPtr,
	property_path: string,
	removed: []undo_ops.Removed_Override,
	snap: engine.Override_Snapshot,
) {
	snap := snap
	u := shell.get()
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if u == nil || !u.recording || u.applying || ht == nil {
		discard_override_removal(removed)
		engine.nested_override_snapshot_destroy(&snap)
		return
	}
	shell.push(u, shell.Command(undo_ops.Dropdown_Revert_Command{
		scene         = scene_ref(s),
		host_local_id = ht.local_id,
		kind          = kind,
		target        = target,
		property_path = strings.clone(property_path),
		removed       = removed,
		snapshot      = snap,
	}), "Revert Override")
}

// Runs a Prefab Apply (engine.nested_scene_apply_entries) and records it as one
// undo step: the files it wrote with their bytes before and after, and the
// instance's records before and after. Returns whether the apply ran.
apply_to_prefab :: proc(
	s: ^engine.Scene,
	host_tH: engine.Transform_Handle,
	target_guid: engine.Asset_GUID,
	entries: []engine.Override_Entry,
	which: ^map[int]bool = nil,
) -> bool {
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	ns := engine.scene_find_nested_scene_for_host(s, host_tH)
	if ht == nil || ns == nil do return false
	host_lid := ht.local_id
	before := engine.nested_records_capture(ns)
	files := make([dynamic]engine.Applied_File)
	if !engine.nested_scene_apply_entries(s, host_tH, target_guid, entries, which, &files) {
		engine.nested_records_destroy(&before)
		engine.applied_files_destroy(files[:])
		delete(files)
		return false
	}
	// The apply re-resolved the instance, so its record is found again by id.
	u := shell.get()
	after_ns := undo_ops.prefab_apply_ns(scene_ref(s), host_lid)
	if u == nil || !u.recording || u.applying || after_ns == nil {
		engine.nested_records_destroy(&before)
		engine.applied_files_destroy(files[:])
		delete(files)
		return true
	}
	shell.push(u, shell.Command(undo_ops.Prefab_Apply_Command{
		scene         = scene_ref(s),
		host_local_id = host_lid,
		files         = files[:],
		before        = before,
		after         = engine.nested_records_capture(after_ns),
	}))
	return true
}

// Attaches override bookkeeping to the CURRENT undo step. Value edits and the
// Revert menu both push their Value_Command standalone rather than inside a
// transaction, so this FOLDS the top entry and the bookkeeping into one
// Group_Command — the two must be inseparable, or a value undo would leave the
// record disagreeing with the value it describes.
@(private)
_override_cmd_attach :: proc(u: ^shell.Undo_Stack, cmd: undo_ops.Record_Override_Command) {
	cmd := cmd
	// Inside a transaction (multi-field edits, gizmo drags): just join it.
	if len(u.txn_stack) > 0 {
		g := &u.txn_stack[len(u.txn_stack) - 1]
		append(&g.subs, shell.Command(cmd))
		return
	}

	// Standalone: fold with the value entry that was pushed a moment ago.
	if u.top <= 0 || u.top > len(u.items) {
		undo_ops.destroy_Record_Override_Command(&cmd)
		return
	}
	e := &u.items[u.top - 1]
	if grp, is_group := &e.cmd.(shell.Group_Command); is_group {
		append(&grp.subs, shell.Command(cmd))
		return
	}
	subs := make([dynamic]shell.Command)
	append(&subs, e.cmd)
	append(&subs, shell.Command(cmd))
	e.cmd = shell.Group_Command{subs = subs}
}
