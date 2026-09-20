package editor

// Pin an inspector to what it is showing, so clicking elsewhere does not take
// it away — Unity's padlock. Both inspectors get one, in their tab bar
// (@(view_tab_bar)), because a lock has to be VISIBLE: an inspector showing
// something other than the selection is confusing until you can see why.
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
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:engine"

// --- Scene inspector ---------------------------------------------------------

@(private = "file") _inspector_locked: bool
@(private = "file") _inspector_lock_sel: [dynamic]engine.Transform_Handle

@(view_tab_bar={view="Inspector", order=0})
_inspector_lock_button :: proc() {
	was := _inspector_locked
	filter_toggle_button(_inspector_locked ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &_inspector_locked)
	if im.IsItemHovered({}) {
		im.SetTooltip(_inspector_locked ? "Unlock: follow the selection again" : "Lock to the current selection")
	}
	if _inspector_locked == was do return
	if _inspector_locked {
		// Take the whole selection, not just the active object: the inspector
		// multi-edits, and a lock that kept one of three would silently change
		// what an edit applies to.
		context.allocator = runtime.default_allocator()
		clear(&_inspector_lock_sel)
		for h in sel_scene_items() do append(&_inspector_lock_sel, h)
	} else {
		clear(&_inspector_lock_sel)
	}
}

// What the inspector draws: the locked set, or the live selection. Dead
// handles are dropped, and a lock left holding nothing releases itself rather
// than leaving the padlock on beside an empty panel.
inspector_targets :: proc() -> []engine.Transform_Handle {
	if !_inspector_locked do return sel_scene_items()
	w := engine.ctx_world()
	live := 0
	for h in _inspector_lock_sel {
		if w != nil && engine.pool_valid(&w.transforms, engine.Handle(h)) {
			_inspector_lock_sel[live] = h
			live += 1
		}
	}
	resize(&_inspector_lock_sel, live)
	if live == 0 {
		_inspector_locked = false
		return sel_scene_items()
	}
	return _inspector_lock_sel[:]
}

// The object whose components the inspector draws — the last of the targets,
// matching the live selection's "most recent wins".
inspector_active_target :: proc() -> engine.Transform_Handle {
	if !_inspector_locked do return hierarchy_get_selected()
	t := inspector_targets()
	if len(t) == 0 do return _HANDLE_NONE
	return t[len(t) - 1]
}

inspector_lock_shutdown :: proc() {
	delete(_inspector_lock_sel)
	_inspector_lock_sel = nil
}

// --- Project inspector -------------------------------------------------------

@(private = "file") _project_inspector_locked: bool

@(view_tab_bar={view="Project Inspector", order=0})
_project_inspector_lock_button :: proc() {
	was := _project_inspector_locked
	filter_toggle_button(_project_inspector_locked ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &_project_inspector_locked)
	if im.IsItemHovered({}) {
		im.SetTooltip(_project_inspector_locked ? "Unlock: follow the project selection again" : "Lock to the current asset")
	}
	// Unlocking CATCHES UP: it retargets to whatever is selected now, rather
	// than holding the stale asset until the next click. The scene inspector
	// does this for free by reading the selection live, and the two should not
	// behave differently just because they are fed differently.
	if was && !_project_inspector_locked {
		if path := projectViewData.selectedFile; path != "" {
			_project_inspect_path(path)
		}
	}
}

// Whether the project view may retarget the project inspector. Locked means it
// keeps whatever it holds — including its unsaved edits, which is most of the
// reason to lock it while picking another file to compare against. Unlocking
// catches up to the current selection, so nothing stays stale.
project_inspector_accepts_target :: proc() -> bool {
	return !_project_inspector_locked
}
