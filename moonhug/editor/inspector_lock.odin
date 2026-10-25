package editor

// Pin an inspector to what it is showing, so clicking elsewhere does not take
// it away. Every instance of both inspectors has its own padlock, in its tab
// bar (@(view_tab_bar)), because a lock has to be VISIBLE: an inspector
// showing something other than the selection is confusing until you can see
// why.
//
// The two are locked by different means, because they are fed differently:
//
// - The scene Inspector reads the live selection every frame, so locking
//   SNAPSHOTS it and the inspector reads the snapshot instead.
// - The Project Inspector is pushed a target when the project view routes a
//   click, so locking just REFUSES those pushes and it keeps what it holds.
//
// Snapshotting the project inspector would mean duplicating its document
// state, and refusing pushes to the scene inspector would mean intercepting
// the selection itself, which the hierarchy highlight also reads.

import "base:runtime"
import "core:strings"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import "moonhug:editor/widgets"
import core "moonhug:libs/core"

// --- Scene inspector ---------------------------------------------------------

// Each Inspector instance's lock, by its key: "Inspector" for the first one,
// "Inspector/2" for another. On the default allocator: they outlive frames.
@(private = "file")
_Scene_Lock :: struct {
	locked: bool,
	sel:    [dynamic]core.Transform_Handle,
}

@(private = "file") _scene_locks: map[string]^_Scene_Lock

@(private = "file")
_scene_lock :: proc(view: string, create: bool) -> ^_Scene_Lock {
	if lock, has := _scene_locks[view]; has do return lock
	if !create do return nil
	context.allocator = runtime.default_allocator()
	lock := new(_Scene_Lock)
	_scene_locks[strings.clone(view)] = lock
	return lock
}

@(view_tab_bar={view="Inspector", order=0})
_inspector_lock_button :: proc(view: session.View) {
	lock := _scene_lock(view.key, create = true)
	locked := lock.locked
	filter_toggle_button(locked ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &locked)
	widgets.tooltip(locked ? "Unlock: follow the selection again" : "Lock to the current selection")
	inspector_lock_set(view.key, locked)
}

// Locks the Inspector instance `view` to the current selection, or unlocks
// it to follow the selection again.
inspector_lock_set :: proc(view: string, locked: bool) {
	lock := _scene_lock(view, create = true)
	if lock.locked == locked do return
	lock.locked = locked
	context.allocator = runtime.default_allocator()
	clear(&lock.sel)
	if locked {
		// Take the whole selection, not just the active object: the inspector
		// multi-edits, and a lock that kept one of three would silently change
		// what an edit applies to.
		for h in sel_scene_inspected() do append(&lock.sel, h)
	}
}

// What the Inspector instance `view` draws: its locked set, or the selected
// objects — which, while the project holds the selection, are the ones it
// last showed (sel_scene_inspected). Dead handles are dropped, and a lock left
// holding nothing releases itself rather than leaving the padlock on beside
// an empty panel.
inspector_targets :: proc(view: string) -> []core.Transform_Handle {
	lock := _scene_lock(view, create = false)
	if lock == nil || !lock.locked do return sel_scene_inspected()
	live := 0
	for h in lock.sel {
		if _object_alive(h) {
			lock.sel[live] = h
			live += 1
		}
	}
	resize(&lock.sel, live)
	if live == 0 {
		lock.locked = false
		return sel_scene_inspected()
	}
	return lock.sel[:]
}

// The object whose components the instance draws — the last of its targets,
// matching the live selection's "most recent wins".
inspector_active_target :: proc(view: string) -> core.Transform_Handle {
	lock := _scene_lock(view, create = false)
	if lock == nil || !lock.locked do return sel_scene_inspected_active()
	t := inspector_targets(view)
	if len(t) == 0 do return _HANDLE_NONE
	return t[len(t) - 1]
}

// Drops the locks of Inspector instances that closed. Once per frame.
inspector_locks_prune :: proc() {
	context.allocator = runtime.default_allocator()
	closed := make([dynamic]string, context.temp_allocator)
	for key in _scene_locks do if key != "Inspector" && wnd.find(key) == nil do append(&closed, key)
	for key in closed {
		k, lock := delete_key(&_scene_locks, key)
		delete(lock.sel)
		free(lock)
		delete(k)
	}
}

inspector_lock_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for key, lock in _scene_locks {
		delete(lock.sel)
		free(lock)
		delete(key)
	}
	delete(_scene_locks)
	_scene_locks = nil
}

// --- Project inspector -------------------------------------------------------

@(view_tab_bar={view="Project Inspector", order=0})
_project_inspector_lock_button :: proc(view: session.View) {
	locked := inspector.project_inspector_lock(view.key)
	if locked == nil do return
	was := locked^
	filter_toggle_button(locked^ ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, locked)
	widgets.tooltip(locked^ ? "Unlock: follow the project selection again" : "Lock to the current asset")
	// Unlocking CATCHES UP: it retargets to whatever is selected now, rather
	// than holding the stale asset until the next click. The scene inspector
	// does this for free by reading the selection live, and the two should not
	// behave differently just because they are fed differently.
	if was && !locked^ {
		if path := projectViewData.selectedFile; path != "" {
			_project_inspect_path(path)
		}
	}
}
