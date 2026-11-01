package editor

// The selection and the view locks across an editor restart, in the user's
// editor settings (UserSettings/editor_settings.json). Both are one person's
// working state, like the open scenes and windows beside them, so they stay
// out of the committed project settings.
//
// - Saved at quit with the rest of the settings (save_editor_settings).
// - A scene object is named by its scene's asset and its local id: session
//   ids and handles start over with every run. An asset by its guid and the
//   sub-asset id of a selected sub-asset (a sprite slice).
// - Restored once, when the scenes the editor reopens have loaded
//   (selection_persist_restore). The selection goes through
//   selection_apply_state, the proc undo uses, so the hierarchy reveals the
//   objects and the project view the assets. Then the view locks
//   (view_lock.odin), every view's the same way. An object or asset gone since
//   the last run drops out, and a lock left with nothing is not restored. The
//   restore is not an undo step.

import "core:encoding/uuid"
import "core:strings"
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
// asset itself. An asset without a guid (a package folder) keeps its path.
Persisted_Asset :: struct {
	guid:   string,
	path:   string `json:"path,omitempty"`,
	sub_id: core.Local_ID,
}

// The selection in undo.Selection_State's shape: objects in click order (the
// last is active), the objects the Inspector keeps while an asset is
// selected, and the selected assets.
Persisted_Selection :: struct {
	objects: [dynamic]Persisted_Object,
	kept:    [dynamic]Persisted_Object,
	assets:  [dynamic]Persisted_Asset,
	// The assets the Project Inspector keeps while objects are selected.
	kept_assets: [dynamic]Persisted_Asset,
}

// A view lock by its key ("Inspector", "Project Inspector/2", "Animation")
// and what it holds, as references (view_lock.odin). An object of a scene
// never saved has nothing that names it next run and is left out.
Persisted_View_Lock :: struct {
	view:    string,
	objects: [dynamic]Persisted_Object,
	assets:  [dynamic]Persisted_Asset,
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
		objects     = _persist_objects_of_items(state.scene),
		kept        = _persist_objects_of_items(state.kept),
		assets      = _persist_assets_of_refs(state.proj),
		kept_assets = _persist_assets_of_refs(state.kept_proj),
	}
	editor_settings.selection = sel

	locks := make([dynamic]Persisted_View_Lock)
	for l in view_locks_held() {
		// Copies: the lock owns its key and paths, and an unlock frees them.
		p := Persisted_View_Lock{view = strings.clone(l.key), objects = make([dynamic]Persisted_Object), assets = make([dynamic]Persisted_Asset)}
		for o in l.objects do if o.scene_guid != {} {
			append(&p.objects, Persisted_Object{scene = uuid.to_string(uuid.Identifier(o.scene_guid)), local_id = o.local_id})
		}
		for a in l.assets {
			pa := Persisted_Asset{path = strings.clone(a.path), sub_id = a.sub_id}
			if a.guid != {} do pa.guid = uuid.to_string(uuid.Identifier(a.guid))
			append(&p.assets, pa)
		}
		if len(p.objects) > 0 || len(p.assets) > 0 do append(&locks, p)
	}
	editor_settings.view_locks = locks
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
	// The undo baseline was allocated under the caller's allocator, so the
	// rebaseline at the end frees it under that one, not the temp one.
	caller_allocator := context.allocator
	context.allocator = context.temp_allocator

	saved := editor_settings.selection
	state := undo.Selection_State{
		scene = _persist_items(saved.objects[:]),
		kept  = _persist_items(saved.kept[:]),
	}
	state.proj = _persist_refs_of_assets(saved.assets[:])
	state.kept_proj = _persist_refs_of_assets(saved.kept_assets[:])
	if len(state.scene) > 0 || len(state.proj) > 0 || len(state.kept) > 0 || len(state.kept_proj) > 0 do selection_apply_state(state)

	// As references: what is not loaded yet waits (view_lock.odin).
	for l in editor_settings.view_locks {
		objects := make([dynamic]View_Lock_Object)
		for o in l.objects {
			id, err := uuid.read(o.scene)
			if err == nil do append(&objects, View_Lock_Object{scene_guid = core.Asset_GUID(id), local_id = o.local_id})
		}
		held := make([dynamic]View_Lock_Asset)
		for a in l.assets {
			va := View_Lock_Asset{path = a.path, sub_id = a.sub_id}
			if id, err := uuid.read(a.guid); err == nil do va.guid = core.Asset_GUID(id)
			if va.guid != {} || va.path != "" do append(&held, va)
		}
		view_lock_restore(l.view, objects[:], held[:])
	}

	// What was just restored is the starting point, not a change to undo.
	context.allocator = caller_allocator
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

@(private = "file")
_persist_assets_of_refs :: proc(refs: []core.PPtr) -> [dynamic]Persisted_Asset {
	out := make([dynamic]Persisted_Asset)
	for r in refs do append(&out, Persisted_Asset{guid = uuid.to_string(uuid.Identifier(r.guid)), sub_id = r.local_id})
	return out
}

// The saved assets that still exist, as references.
@(private = "file")
_persist_refs_of_assets :: proc(saved: []Persisted_Asset) -> []core.PPtr {
	out := make([dynamic]core.PPtr)
	for a in saved {
		id, err := uuid.read(a.guid)
		if err != nil do continue
		if _, known := assets.asset_db_get_path(id); !known do continue
		append(&out, core.PPtr{guid = core.Asset_GUID(id), local_id = a.sub_id})
	}
	return out[:]
}

