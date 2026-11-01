package editor

// The selection and the locked inspectors across an editor restart, in the
// user's editor settings (UserSettings/editor_settings.json). Both are one
// person's working state, like the open scenes and windows beside them, so
// they stay out of the committed project settings.
//
// - Saved at quit with the rest of the settings (save_editor_settings).
// - A scene object is named by its scene's asset and its local id: session
//   ids and handles start over with every run. An asset by its guid and the
//   sub-asset id of a selected sub-asset (a sprite slice).
// - Restored once, when the scenes the editor reopens have loaded
//   (selection_persist_restore). The selection goes through
//   selection_apply_state, the proc undo uses, so the hierarchy reveals the
//   objects and the project view the assets. Then the inspector locks. An
//   object or asset gone since the last run drops out, and a lock left with
//   nothing is not restored. The restore is not an undo step.

import "core:encoding/uuid"
import assets "moonhug:libs/assets"
import "moonhug:editor/inspector"
import "moonhug:editor/simulate"
import "moonhug:editor/undo"
import core "moonhug:libs/core"

// A scene object across a restart: its scene's asset guid and its local id.
Persisted_Object :: struct {
	scene:    string,
	local_id: core.Local_ID,
}

// An asset across a restart: its guid and the selected sub-asset, 0 for the
// asset itself.
Persisted_Asset :: struct {
	guid:   string,
	sub_id: core.Local_ID,
}

// The selection in undo.Selection_State's shape: objects in click order (the
// last is active), the objects the Inspector keeps while an asset is
// selected, and the selected assets.
Persisted_Selection :: struct {
	objects: [dynamic]Persisted_Object,
	kept:    [dynamic]Persisted_Object,
	assets:  [dynamic]Persisted_Asset,
}

// A locked Inspector instance by its key ("Inspector", "Inspector/2") and
// the objects it holds.
Persisted_Inspector_Lock :: struct {
	view:    string,
	objects: [dynamic]Persisted_Object,
}

// A locked Project Inspector instance by its key and the asset it holds. A
// package root has no guid and keeps its path.
Persisted_Project_Lock :: struct {
	view: string,
	guid: string,
	path: string,
}

// Fills the editor settings' selection and lock fields from the editor as it
// is now. Temp-allocated, as save_editor_settings writes the file at once.
selection_persist_capture :: proc() {
	// Quit before the restore ran (scenes still loading): what was saved has
	// not been seen yet, so it stays.
	if !_persist_restored do return
	context.allocator = context.temp_allocator
	state := selection_capture_state()
	defer undo.selection_state_destroy(&state)
	sel := Persisted_Selection{
		objects = _persist_objects_of_items(state.scene),
		kept    = _persist_objects_of_items(state.kept),
		assets  = make([dynamic]Persisted_Asset),
	}
	for r in state.proj {
		append(&sel.assets, Persisted_Asset{guid = uuid.to_string(uuid.Identifier(r.guid)), sub_id = r.local_id})
	}
	editor_settings.selection = sel

	locks := make([dynamic]Persisted_Inspector_Lock)
	for l in inspector_locked_views() {
		objects := _persist_objects_of_handles(l.targets)
		if len(objects) > 0 do append(&locks, Persisted_Inspector_Lock{view = l.view, objects = objects})
	}
	editor_settings.inspector_locks = locks

	plocks := make([dynamic]Persisted_Project_Lock)
	for l in inspector.project_inspector_locked() {
		p := Persisted_Project_Lock{view = l.key, path = l.path}
		if guid, ok := assets.asset_db_get_guid(l.path); ok do p.guid = uuid.to_string(guid)
		append(&plocks, p)
	}
	editor_settings.project_inspector_locks = plocks
}

@(private = "file")
_persist_objects_of_items :: proc(items: []undo.Selection_Scene_Item) -> [dynamic]Persisted_Object {
	out := make([dynamic]Persisted_Object)
	for it in items {
		guid := simulate.world_scene_asset(it.scene)
		if guid == {} do continue // an unsaved scene: nothing names it next run
		append(&out, Persisted_Object{scene = uuid.to_string(uuid.Identifier(guid)), local_id = it.local_id})
	}
	return out
}

@(private = "file")
_persist_objects_of_handles :: proc(handles: []core.Transform_Handle) -> [dynamic]Persisted_Object {
	items := make([dynamic]undo.Selection_Scene_Item)
	for h in handles {
		local_id, alive := inspector.object_local_id(h)
		if alive do append(&items, undo.Selection_Scene_Item{scene = inspector.object_scene(h), local_id = local_id})
	}
	return _persist_objects_of_items(items[:])
}

// The saved object as a live one, false when its scene is not loaded or the
// object is gone.
@(private = "file")
_persist_resolve :: proc(o: Persisted_Object) -> (item: undo.Selection_Scene_Item, ok: bool) {
	id, err := uuid.read(o.scene)
	if err != nil do return {}, false
	scene := simulate.world_scene_of_asset(core.Asset_GUID(id))
	if scene == {} do return {}, false
	if _, alive := simulate.world_select_restored(scene, o.local_id); !alive do return {}, false
	return undo.Selection_Scene_Item{scene = scene, local_id = o.local_id}, true
}

@(private = "file")
_persist_restored: bool

// Restores the saved selection and inspector locks, once per run. The main
// loop calls it every frame from the first frame the reopened scenes are all
// loaded. It does nothing after the first call.
selection_persist_restore :: proc() {
	if _persist_restored do return
	_persist_restored = true
	context.allocator = context.temp_allocator

	saved := editor_settings.selection
	state := undo.Selection_State{
		scene = _persist_items(saved.objects[:]),
		kept  = _persist_items(saved.kept[:]),
	}
	proj := make([dynamic]core.PPtr)
	for a in saved.assets {
		id, err := uuid.read(a.guid)
		if err != nil do continue
		if _, known := assets.asset_db_get_path(id); !known do continue
		append(&proj, core.PPtr{guid = core.Asset_GUID(id), local_id = a.sub_id})
	}
	state.proj = proj[:]
	if len(state.scene) > 0 || len(state.proj) > 0 do selection_apply_state(state)

	for l in editor_settings.inspector_locks {
		targets := make([dynamic]core.Transform_Handle)
		for it in _persist_items(l.objects[:]) {
			if tH, ok := simulate.world_select_restored(it.scene, it.local_id); ok do append(&targets, tH)
		}
		if len(targets) > 0 do inspector_lock_restore(l.view, targets[:])
	}

	for l in editor_settings.project_inspector_locks {
		path := l.path
		if id, err := uuid.read(l.guid); err == nil {
			if p, known := assets.asset_db_get_path(id); known do path = p
		}
		if path != "" do project_inspector_lock_restore(l.view, path)
	}

	// What was just restored is the starting point, not a change to undo.
	selection_undo_rebaseline()
}

@(private = "file")
_persist_items :: proc(objects: []Persisted_Object) -> []undo.Selection_Scene_Item {
	out := make([dynamic]undo.Selection_Scene_Item)
	for o in objects do if it, ok := _persist_resolve(o); ok do append(&out, it)
	return out[:]
}

// Test-only: marks the saved state as restored or not, so a test can capture
// (which waits for a restore) and restore again within one run.
selection_persist_set_restored_for_test :: proc(restored: bool) {
	_persist_restored = restored
}

