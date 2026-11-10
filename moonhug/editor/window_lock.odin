package editor

// Window locks: the padlock in a window's tab bar pins the window to what is
// selected now, so selecting something else does not take it away. One lock
// for every window that has a padlock (@(editor_window) lock), so they all
// behave alike:
//
//   - Locking takes the selection as it is now, both sets: the selected
//     objects, or the ones kept while assets are selected
//     (sel_scene_inspected), and the selected assets with their sub-asset
//     ids, or the ones kept while objects are selected (sel_proj_inspected).
//     With nothing selected there is nothing to hold, and the window stays
//     unlocked
//   - A lock holds references, not handles: an object as its scene's asset
//     guid (the scene's session id for a scene never saved) and its local id,
//     an asset as its guid (its path when it has none, a package folder) and
//     its sub-asset id. The window asks every frame and gets what resolves now
//     (window_objects, window_assets)
//   - What does not resolve is missing, not gone: the scene is closed, the
//     object deleted, the asset moved out. The lock stays, the window says so
//     (window_lock_missing), and shows it again when it is back: the scene
//     reopens, an undo brings the object back. The same local id never names
//     another object: the engine mints ids at random among 2^63 and checks
//     the live ones, and an undo restores an object with its own id
//   - The lock goes when the window is unlocked, or when its window closed
//     after it was open and cannot come back under its key (window_locks_prune).
//     While it can, the lock waits: Reopen Closed brings the window back, or
//     the workspace that hosted it shows it again (window.can_reopen), and the
//     window is locked as it was. A window opened fresh under that key starts
//     unlocked. A lock waiting for its window (restored after a restart, in a
//     workspace not hosted yet) waits as long as it takes
//   - The lock's key is the window instance's key for an "instance" lock, the
//     window's id for a "shared" one (window_lock_key)
//   - Locks survive a restart: a docked or floating window's in the user
//     settings (selection_persist.odin), a workspace frame's window's in its
//     workspace (workspace.Saved_Window, kept equal by workspace_locks_sync), so it
//     goes where the workspace goes
//
// Windows and plugins reach it through the session package (session.window_*).

import "base:runtime"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/simulate"
import wnd "moonhug:editor/window"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

// An object a lock holds.
Window_Lock_Object :: struct {
	scene_guid: core.Asset_GUID, // the scene's asset, empty for a scene never saved
	scene:      core.Scene_Ref,  // the scene's session id, for a scene never saved
	local_id:   core.Local_ID,
}

// An asset a lock holds.
Window_Lock_Asset :: struct {
	guid:   core.Asset_GUID,
	path:   string, // owned: the path for an asset without a guid (a package folder)
	sub_id: core.Local_ID,
}

@(private = "file")
_Window_Lock :: struct {
	objects: [dynamic]Window_Lock_Object,
	assets:  [dynamic]Window_Lock_Asset,
	// Its window was open at some point since the lock was made or restored:
	// only then does a missing window mean the window closed.
	seen:    bool,
	// Its window closed and can come back under its key: the lock waits for
	// a reopen, and a window opened fresh drops it.
	away:    bool,
}

// By lock key. On the default allocator: they outlive frames.
@(private = "file")
_window_locks: map[string]^_Window_Lock

// The key of the lock window instance `window` uses: its own key, or its
// window's id when the window's instances share one lock.
window_lock_key :: proc(window: string) -> string {
	v := session.window_ref_of(window)
	if wnd.lock_mode(v.id) == .Shared do return v.id
	return window
}

@(private = "file")
_lock_of :: proc(window: string) -> ^_Window_Lock {
	return _window_locks[window_lock_key(window)]
}

@(private = "file")
_lock_free :: proc(lock: ^_Window_Lock) {
	context.allocator = runtime.default_allocator()
	for a in lock.assets do delete(a.path)
	delete(lock.assets)
	delete(lock.objects)
	free(lock)
}

@(private = "file")
_lock_drop :: proc(key: string) {
	if key not_in _window_locks do return
	k, lock := delete_key(&_window_locks, key)
	_lock_free(lock)
	delete(k, runtime.default_allocator())
}

// Locks window `window` to the selection as it is now, or unlocks it to follow
// the selection again. With nothing selected the window stays unlocked.
window_lock_set :: proc(window: string, locked: bool) {
	_lock_drop(window_lock_key(window))
	if !locked do return
	objects := make([dynamic]Window_Lock_Object, context.temp_allocator)
	for h in sel_scene_inspected() {
		if o, ok := _lock_object_of(h); ok do append(&objects, o)
	}
	assets_held := make([dynamic]Window_Lock_Asset, context.temp_allocator)
	for e in sel_proj_inspected() do append(&assets_held, _lock_asset_of(e.path, e.sub_id))
	window_lock_restore(window, objects[:], assets_held[:])
	// Locked from the window's own padlock: its window is open.
	if lock := _lock_of(window); lock != nil do lock.seen = true
}

// Locks window `window` to `objects` and `assets`, copied: a lock it held when
// the editor last quit (selection_persist.odin). Nothing to hold, no lock.
window_lock_restore :: proc(window: string, objects: []Window_Lock_Object, assets_held: []Window_Lock_Asset) {
	key := window_lock_key(window)
	_lock_drop(key)
	if len(objects) == 0 && len(assets_held) == 0 do return
	context.allocator = runtime.default_allocator()
	lock := new(_Window_Lock)
	append(&lock.objects, ..objects)
	for a in assets_held do append(&lock.assets, Window_Lock_Asset{guid = a.guid, path = strings.clone(a.path), sub_id = a.sub_id})
	_window_locks[strings.clone(key)] = lock
}

@(private = "file")
_lock_object_of :: proc(h: core.Transform_Handle) -> (Window_Lock_Object, bool) {
	local_id, alive := inspector.object_local_id(h)
	if !alive do return {}, false
	scene := inspector.object_scene(h)
	return Window_Lock_Object{scene_guid = simulate.world_scene_asset(scene), scene = scene, local_id = local_id}, true
}

@(private = "file")
_lock_asset_of :: proc(path: string, sub_id: core.Local_ID) -> Window_Lock_Asset {
	a := Window_Lock_Asset{sub_id = sub_id}
	if guid, ok := assets.asset_db_get_guid(path); ok {
		a.guid = core.Asset_GUID(guid)
	} else {
		a.path = path
	}
	return a
}

// The object `o` names, now: false while its scene is closed or the object
// is gone.
@(private = "file")
_lock_object_resolve :: proc(o: Window_Lock_Object) -> (core.Transform_Handle, bool) {
	scene := o.scene
	if o.scene_guid != {} do scene = simulate.world_scene_of_asset(o.scene_guid)
	if scene == {} do return {}, false
	return simulate.world_select_restored(scene, o.local_id)
}

// The path `a` names, now: false while the asset is gone.
@(private = "file")
_lock_asset_resolve :: proc(a: Window_Lock_Asset) -> (string, bool) {
	if a.guid != {} do return assets.asset_db_get_path(uuid.Identifier(a.guid))
	return a.path, a.path != "" && os.exists(a.path)
}

window_locked :: proc(window: string) -> bool {
	return _lock_of(window) != nil
}

// The objects window `window` shows: what its lock holds and resolves now, or
// the selection (the objects kept while assets are selected included).
// Temp-allocated while locked.
window_objects :: proc(window: string) -> []core.Transform_Handle {
	lock := _lock_of(window)
	if lock == nil do return sel_scene_inspected()
	out := make([dynamic]core.Transform_Handle, context.temp_allocator)
	for o in lock.objects do if h, ok := _lock_object_resolve(o); ok do append(&out, h)
	return out[:]
}

// The object window `window` acts on: the last of its objects, matching the
// selection's "most recent wins". {} when there is none.
window_object :: proc(window: string) -> core.Transform_Handle {
	objects := window_objects(window)
	if len(objects) == 0 do return _HANDLE_NONE
	return objects[len(objects) - 1]
}

// The assets window `window` shows: what its lock holds and resolves now, or the
// project selection (the assets kept while objects are selected included).
// Temp-allocated.
window_assets :: proc(window: string) -> []session.Window_Asset {
	out := make([dynamic]session.Window_Asset, context.temp_allocator)
	lock := _lock_of(window)
	if lock == nil {
		for e in sel_proj_inspected() do append(&out, session.Window_Asset{path = e.path, sub_id = e.sub_id})
		return out[:]
	}
	for a in lock.assets do if path, ok := _lock_asset_resolve(a); ok do append(&out, session.Window_Asset{path = path, sub_id = a.sub_id})
	return out[:]
}

// Whether window `window` is locked and nothing its lock holds resolves now.
window_lock_missing :: proc(window: string) -> bool {
	lock := _lock_of(window)
	if lock == nil do return false
	return len(window_objects(window)) == 0 && len(window_assets(window)) == 0
}

// A lock and what it holds, for saving. Borrowed.
Window_Lock_Held :: struct {
	key:     string,
	objects: []Window_Lock_Object,
	assets:  []Window_Lock_Asset,
}

// The locks the user settings save (selection_persist.odin). Left out: a
// lock waiting for a closed window, since the closed list does not outlive
// the session, and the lock of a window a workspace frame holds, which its
// workspace saves.
window_locks_held :: proc(allocator := context.temp_allocator) -> []Window_Lock_Held {
	out := make([dynamic]Window_Lock_Held, allocator)
	for key, lock in _window_locks {
		if lock.away || wnd.is_kept(key) do continue
		append(&out, Window_Lock_Held{key = key, objects = lock.objects[:], assets = lock.assets[:]})
	}
	return out[:]
}

// The lock of the window instance `window` alone, for its workspace to save.
// false when it is unlocked, or its window's instances share one lock: a
// shared lock is not one instance's to carry.
window_lock_held :: proc(window: string) -> (Window_Lock_Held, bool) {
	if window_lock_key(window) != window do return {}, false
	lock := _window_locks[window]
	if lock == nil do return {}, false
	return Window_Lock_Held{key = window, objects = lock.objects[:], assets = lock.assets[:]}, true
}

// Whether the window a lock key names is open: the instance, or for a shared
// lock any instance of the window.
@(private = "file")
_lock_window_open :: proc(key: string) -> bool {
	if wnd.find(key) != nil do return true
	if wnd.lock_mode(key) == .Shared do return len(wnd.instances(key)) > 0
	return false
}

// Whether the window a lock key names can come back under the key, its
// instance or for a shared lock any instance of the window.
@(private = "file")
_lock_window_can_reopen :: proc(key: string) -> bool {
	if wnd.lock_mode(key) == .Shared do return wnd.can_reopen_id(key)
	return wnd.can_reopen(key)
}

// Whether the open window a lock key names was reopened, not opened fresh:
// its instance, or for a shared lock any instance of the window.
@(private = "file")
_lock_window_reopened :: proc(key: string) -> bool {
	if w := wnd.find(key); w != nil do return w.reopened
	if wnd.lock_mode(key) == .Shared {
		for w in wnd.instances(key) do if w.reopened do return true
	}
	return false
}

// Once per frame. A lock whose window closed waits while the window can come
// back under its key, and goes when it cannot. A reopened window takes its
// lock back, and a window opened fresh under the key drops it.
window_locks_prune :: proc() {
	dropped := make([dynamic]string, context.temp_allocator)
	for key, lock in _window_locks {
		switch {
		case _lock_window_open(key):
			if lock.away && !_lock_window_reopened(key) {
				append(&dropped, key)
				continue
			}
			lock.seen = true
			lock.away = false
		case !lock.seen:
			// Restored after a restart, its window not here yet: it waits.
		case _lock_window_can_reopen(key):
			lock.away = true
		case:
			append(&dropped, key)
		}
	}
	for key in dropped do _lock_drop(key)
}

window_locks_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for key, lock in _window_locks {
		_lock_free(lock)
		delete(key)
	}
	delete(_window_locks)
	_window_locks = nil
}

// The sub-asset of `path` the Project Inspector instance being drawn shows
// (inspector.selected_sub): its lock's when it is locked, the selection's
// otherwise.
_inspected_sub :: proc(path: string) -> core.Local_ID {
	key := inspector.project_inspector_drawing()
	if key == "" || !window_locked(key) do return sel_proj_active_sub(path)
	held := window_assets(key)
	for i := len(held) - 1; i >= 0; i -= 1 do if held[i].path == path do return held[i].sub_id
	return 0
}

