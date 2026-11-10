package editor

// The selection, the window locks and the windows' saved state across an
// editor restart, in the user's editor settings
// (UserSettings/editor_settings.json). All are one person's
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
//   objects and the Project window the assets. Then the window locks
//   (window_lock.odin), every window's the same way. An object or asset gone since
//   the last run drops out, and a lock left with nothing is not restored. The
//   restore is not an undo step.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import assets "moonhug:libs/assets"
import "moonhug:editor/inspector"
import "moonhug:editor/simulate"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
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

// What is saved for a window, by its key ("Inspector", "Project Inspector/2",
// "Animation"):
//
// - What its lock holds, as references (window_lock.odin), empty for an
//   unlocked window. An object of a scene never saved has nothing that names
//   it next run and is left out.
// - Its saved state (window/window_saved.odin), nil for a window without one.
//
// A window of a workspace frame is not here: its workspace saves it.
Persisted_Window :: struct {
	window:  string,
	objects: [dynamic]Persisted_Object `json:"objects,omitempty"`,
	assets:  [dynamic]Persisted_Asset `json:"assets,omitempty"`,
	state:   json.Value `json:"state,omitempty"`,
}

// The record of the window `key` in `list`, added when missing.
@(private = "file")
_persist_window :: proc(list: ^[dynamic]Persisted_Window, key: string) -> ^Persisted_Window {
	for &p in list do if p.window == key do return &p
	append(list, Persisted_Window{window = key})
	return &list[len(list) - 1]
}

// Gives the window registry the saved states the settings hold, before the
// windows of the last session open (window.open_saved).
window_states_restore :: proc() {
	for p in editor_settings.windows {
		if p.state == nil do continue
		text, err := json.marshal(p.state, {spec = .JSON}, context.temp_allocator)
		if err == nil do wnd.saved_set(p.window, string(text))
	}
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

	windows := make([dynamic]Persisted_Window)
	for l in window_locks_held() {
		// Copies: the lock owns its key and paths, and an unlock frees them.
		objects := make([dynamic]Persisted_Object)
		for o in l.objects do if o.scene_guid != {} {
			append(&objects, Persisted_Object{scene = uuid.to_string(uuid.Identifier(o.scene_guid)), local_id = o.local_id})
		}
		held := make([dynamic]Persisted_Asset)
		for a in l.assets {
			pa := Persisted_Asset{path = strings.clone(a.path), sub_id = a.sub_id}
			if a.guid != {} do pa.guid = uuid.to_string(uuid.Identifier(a.guid))
			append(&held, pa)
		}
		if len(objects) == 0 && len(held) == 0 do continue
		p := _persist_window(&windows, strings.clone(l.key))
		p.objects, p.assets = objects, held
	}
	// The saved states: an open window's, and a plain instance's, which
	// shows as it was left when its window opens again. Another closed
	// instance does not come back under its key after a restart.
	for key in wnd.saved_keys() {
		if wnd.is_kept(key) do continue
		if wnd.find(key) == nil && strings.index_byte(key, '/') >= 0 do continue
		state, err := json.parse_string(wnd.saved_text(key), .JSON, true)
		if err != nil do continue
		_persist_window(&windows, strings.clone(key)).state = state
	}
	editor_settings.windows = windows
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

	// As references: what is not loaded yet waits (window_lock.odin).
	for l in editor_settings.windows {
		if len(l.objects) == 0 && len(l.assets) == 0 do continue
		objects := make([dynamic]Window_Lock_Object)
		for o in l.objects {
			id, err := uuid.read(o.scene)
			if err == nil do append(&objects, Window_Lock_Object{scene_guid = core.Asset_GUID(id), local_id = o.local_id})
		}
		held := make([dynamic]Window_Lock_Asset)
		for a in l.assets {
			va := Window_Lock_Asset{path = a.path, sub_id = a.sub_id}
			if id, err := uuid.read(a.guid); err == nil do va.guid = core.Asset_GUID(id)
			if va.guid != {} || va.path != "" do append(&held, va)
		}
		window_lock_restore(l.window, objects[:], held[:])
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

