package editor

// View locks: the padlock in a view's tab bar pins the view to what is
// selected now, so selecting something else does not take it away. One lock
// for every view that has a padlock (@(editor_window) lock), so they all
// behave alike:
//
//   - Locking takes the selection as it is now, both sets: the selected
//     objects, or the ones kept while assets are selected
//     (sel_scene_inspected), and the selected assets with their sub-asset
//     ids, or the ones kept while objects are selected (sel_proj_inspected).
//     With nothing selected there is nothing to hold, and the view stays
//     unlocked
//   - A lock holds references, not handles: an object as its scene's asset
//     guid (the scene's session id for a scene never saved) and its local id,
//     an asset as its guid (its path when it has none, a package folder) and
//     its sub-asset id. The view asks every frame and gets what resolves now
//     (view_objects, view_assets)
//   - What does not resolve is missing, not gone: the scene is closed, the
//     object deleted, the asset moved out. The lock stays, the view says so
//     (view_lock_missing), and shows it again when it is back: the scene
//     reopens, an undo brings the object back. The same local id never names
//     another object: the engine mints ids at random among 2^63 and checks
//     the live ones, and an undo restores an object with its own id
//   - The lock goes when the view is unlocked, or when its view closes after
//     it was open (view_locks_prune). A lock waiting for its view (restored
//     after a restart, in a workspace not hosted yet) waits as long as it
//     takes
//   - The lock's key is the view instance's key for an "instance" lock, the
//     window's id for a "shared" one (view_lock_key)
//   - Locks survive a restart (selection_persist.odin)
//
// Views and plugins reach it through the session package (session.view_*).

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
View_Lock_Object :: struct {
	scene_guid: core.Asset_GUID, // the scene's asset, empty for a scene never saved
	scene:      core.Scene_Ref,  // the scene's session id, for a scene never saved
	local_id:   core.Local_ID,
}

// An asset a lock holds.
View_Lock_Asset :: struct {
	guid:   core.Asset_GUID,
	path:   string, // owned: the path for an asset without a guid (a package folder)
	sub_id: core.Local_ID,
}

@(private = "file")
_View_Lock :: struct {
	objects: [dynamic]View_Lock_Object,
	assets:  [dynamic]View_Lock_Asset,
	// Its view was open at some point since the lock was made or restored:
	// only then does a missing view mean the view closed.
	seen:    bool,
}

// By lock key. On the default allocator: they outlive frames.
@(private = "file")
_view_locks: map[string]^_View_Lock

// The key of the lock view instance `view` uses: its own key, or its
// window's id when the window's instances share one lock.
view_lock_key :: proc(view: string) -> string {
	v := session.view_of(view)
	if wnd.lock_mode(v.id) == .Shared do return v.id
	return view
}

@(private = "file")
_lock_of :: proc(view: string) -> ^_View_Lock {
	return _view_locks[view_lock_key(view)]
}

@(private = "file")
_lock_free :: proc(lock: ^_View_Lock) {
	context.allocator = runtime.default_allocator()
	for a in lock.assets do delete(a.path)
	delete(lock.assets)
	delete(lock.objects)
	free(lock)
}

@(private = "file")
_lock_drop :: proc(key: string) {
	if key not_in _view_locks do return
	k, lock := delete_key(&_view_locks, key)
	_lock_free(lock)
	delete(k, runtime.default_allocator())
}

// Locks view `view` to the selection as it is now, or unlocks it to follow
// the selection again. With nothing selected the view stays unlocked.
view_lock_set :: proc(view: string, locked: bool) {
	_lock_drop(view_lock_key(view))
	if !locked do return
	objects := make([dynamic]View_Lock_Object, context.temp_allocator)
	for h in sel_scene_inspected() {
		if o, ok := _lock_object_of(h); ok do append(&objects, o)
	}
	assets_held := make([dynamic]View_Lock_Asset, context.temp_allocator)
	for e in sel_proj_inspected() do append(&assets_held, _lock_asset_of(e.path, e.sub_id))
	view_lock_restore(view, objects[:], assets_held[:])
	// Locked from the view's own padlock: its view is open.
	if lock := _lock_of(view); lock != nil do lock.seen = true
}

// Locks view `view` to `objects` and `assets`, copied: a lock it held when
// the editor last quit (selection_persist.odin). Nothing to hold, no lock.
view_lock_restore :: proc(view: string, objects: []View_Lock_Object, assets_held: []View_Lock_Asset) {
	key := view_lock_key(view)
	_lock_drop(key)
	if len(objects) == 0 && len(assets_held) == 0 do return
	context.allocator = runtime.default_allocator()
	lock := new(_View_Lock)
	append(&lock.objects, ..objects)
	for a in assets_held do append(&lock.assets, View_Lock_Asset{guid = a.guid, path = strings.clone(a.path), sub_id = a.sub_id})
	_view_locks[strings.clone(key)] = lock
}

@(private = "file")
_lock_object_of :: proc(h: core.Transform_Handle) -> (View_Lock_Object, bool) {
	local_id, alive := inspector.object_local_id(h)
	if !alive do return {}, false
	scene := inspector.object_scene(h)
	return View_Lock_Object{scene_guid = simulate.world_scene_asset(scene), scene = scene, local_id = local_id}, true
}

@(private = "file")
_lock_asset_of :: proc(path: string, sub_id: core.Local_ID) -> View_Lock_Asset {
	a := View_Lock_Asset{sub_id = sub_id}
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
_lock_object_resolve :: proc(o: View_Lock_Object) -> (core.Transform_Handle, bool) {
	scene := o.scene
	if o.scene_guid != {} do scene = simulate.world_scene_of_asset(o.scene_guid)
	if scene == {} do return {}, false
	return simulate.world_select_restored(scene, o.local_id)
}

// The path `a` names, now: false while the asset is gone.
@(private = "file")
_lock_asset_resolve :: proc(a: View_Lock_Asset) -> (string, bool) {
	if a.guid != {} do return assets.asset_db_get_path(uuid.Identifier(a.guid))
	return a.path, a.path != "" && os.exists(a.path)
}

view_locked :: proc(view: string) -> bool {
	return _lock_of(view) != nil
}

// The objects view `view` shows: what its lock holds and resolves now, or
// the selection (the objects kept while assets are selected included).
// Temp-allocated while locked.
view_objects :: proc(view: string) -> []core.Transform_Handle {
	lock := _lock_of(view)
	if lock == nil do return sel_scene_inspected()
	out := make([dynamic]core.Transform_Handle, context.temp_allocator)
	for o in lock.objects do if h, ok := _lock_object_resolve(o); ok do append(&out, h)
	return out[:]
}

// The object view `view` acts on: the last of its objects, matching the
// selection's "most recent wins". {} when there is none.
view_object :: proc(view: string) -> core.Transform_Handle {
	objects := view_objects(view)
	if len(objects) == 0 do return _HANDLE_NONE
	return objects[len(objects) - 1]
}

// The assets view `view` shows: what its lock holds and resolves now, or the
// project selection (the assets kept while objects are selected included).
// Temp-allocated.
view_assets :: proc(view: string) -> []session.View_Asset {
	out := make([dynamic]session.View_Asset, context.temp_allocator)
	lock := _lock_of(view)
	if lock == nil {
		for e in sel_proj_inspected() do append(&out, session.View_Asset{path = e.path, sub_id = e.sub_id})
		return out[:]
	}
	for a in lock.assets do if path, ok := _lock_asset_resolve(a); ok do append(&out, session.View_Asset{path = path, sub_id = a.sub_id})
	return out[:]
}

// Whether view `view` is locked and nothing its lock holds resolves now.
view_lock_missing :: proc(view: string) -> bool {
	lock := _lock_of(view)
	if lock == nil do return false
	return len(view_objects(view)) == 0 && len(view_assets(view)) == 0
}

// A lock and what it holds, for saving (selection_persist.odin). Borrowed.
View_Lock_Held :: struct {
	key:     string,
	objects: []View_Lock_Object,
	assets:  []View_Lock_Asset,
}

view_locks_held :: proc(allocator := context.temp_allocator) -> []View_Lock_Held {
	out := make([dynamic]View_Lock_Held, allocator)
	for key, lock in _view_locks do append(&out, View_Lock_Held{key = key, objects = lock.objects[:], assets = lock.assets[:]})
	return out[:]
}

// Whether the view a lock key names is open: the instance, or for a shared
// lock any instance of the window.
@(private = "file")
_lock_view_open :: proc(key: string) -> bool {
	if wnd.find(key) != nil do return true
	if wnd.lock_mode(key) == .Shared do return len(wnd.instances(key)) > 0
	return false
}

// Drops the locks of views that closed: open at some point since the lock
// was made or restored, and not open now. Once per frame.
view_locks_prune :: proc() {
	closed := make([dynamic]string, context.temp_allocator)
	for key, lock in _view_locks {
		if _lock_view_open(key) {
			lock.seen = true
		} else if lock.seen {
			append(&closed, key)
		}
	}
	for key in closed do _lock_drop(key)
}

view_locks_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for key, lock in _view_locks {
		_lock_free(lock)
		delete(key)
	}
	delete(_view_locks)
	_view_locks = nil
}

// The sub-asset of `path` the Project Inspector instance being drawn shows
// (inspector.selected_sub): its lock's when it is locked, the selection's
// otherwise.
_inspected_sub :: proc(path: string) -> core.Local_ID {
	key := inspector.project_inspector_drawing()
	if key == "" || !view_locked(key) do return sel_proj_active_sub(path)
	held := view_assets(key)
	for i := len(held) - 1; i >= 0; i -= 1 do if held[i].path == path do return held[i].sub_id
	return 0
}

