package animation_editor

// The Animation window's lock: a padlock in its tab bar, as the inspectors
// have. Locked, the window keeps the animated object it shows whatever is
// selected. Unlocked, it follows the selection again (the object the tool
// windows follow, engine.inspector_inspected_selection). The preview is
// shared by every copy of the window (_pv), so the lock is too: each copy's
// padlock shows and toggles the same lock.
//
// The lock survives a restart: the locked object is saved in the window's
// user settings (anim_view_prefs) as its scene's asset guid and its local id,
// and locked again once that scene is loaded. An object deleted since, or
// deleted while locked, releases the lock.

import "core:encoding/uuid"
import engine "moonhug:packages/engine"
import "moonhug:editor/icons"
import "moonhug:editor/session"
import "moonhug:editor/widgets"

@(private = "file")
_anim_lock: struct {
	locked: bool,
	owner:  engine.Transform_Handle,
}

@(view_tab_bar={view="Animation", order=0})
_anim_lock_button :: proc(view: session.View) {
	locked := _anim_lock.locked
	widgets.toggle_button(locked ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &locked)
	widgets.tooltip(locked ? "Unlock: follow the selection again" : "Lock to the object shown")
	if locked != _anim_lock.locked do animation_view_lock_set(locked)
}

// Locks the window to the animated object it shows, or unlocks it to follow
// the selection again. Locking with no object shown does nothing.
animation_view_lock_set :: proc(locked: bool) {
	if !locked {
		_anim_lock = {}
		_anim_lock_save({})
		return
	}
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) do return
	_anim_lock = {locked = true, owner = _pv.owner}
	_anim_lock_save(_pv.owner)
}

// Whether the window is locked, for tests and tools.
animation_view_locked :: proc() -> bool {
	return _anim_lock.locked
}

// The saved lock in the user settings: `tH`'s scene asset and local id, or
// nothing for {} or an object of a scene never saved.
@(private = "file")
_anim_lock_save :: proc(tH: engine.Transform_Handle) {
	delete(anim_view_prefs.locked_scene)
	anim_view_prefs.locked_scene = ""
	anim_view_prefs.locked_object = 0
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil || engine.asset_guid_is_empty(t.scene_asset_guid) do return
	anim_view_prefs.locked_scene = uuid.to_string(uuid.Identifier(t.scene_asset_guid))
	anim_view_prefs.locked_object = t.local_id
}

// The object the window follows: the locked one, else the selection. A
// saved lock waiting for its scene is taken up here, once the scene is
// loaded. A locked object that died releases the lock.
@(private)
_anim_lock_target :: proc() -> engine.Transform_Handle {
	_anim_lock_take_saved()
	if !_anim_lock.locked do return engine.inspector_inspected_selection()
	w := engine.ctx_world()
	if engine.pool_valid(&w.transforms, engine.Handle(_anim_lock.owner)) do return _anim_lock.owner
	animation_view_lock_set(false)
	return engine.inspector_inspected_selection()
}

@(private = "file")
_anim_lock_take_saved :: proc() {
	if _anim_lock.locked || anim_view_prefs.locked_scene == "" do return
	id, err := uuid.read(anim_view_prefs.locked_scene)
	if err != nil {
		_anim_lock_save({})
		return
	}
	s := engine.sm_scene_find_by_guid(engine.Asset_GUID(id))
	if s == nil do return // not loaded yet: the editor reopens scenes one per frame
	tH, found := engine.scene_find_selectable_transform_local_id(s, anim_view_prefs.locked_object)
	if !found {
		_anim_lock_save({}) // deleted since the lock was saved
		return
	}
	_anim_lock = {locked = true, owner = tH}
}

// Test-only: forgets the live lock and keeps the saved one, as a restart does.
animation_view_lock_forget_for_test :: proc() {
	_anim_lock = {}
}
