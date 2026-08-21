package editor

// Edit-menu selection ops and GameObject create items (Unity's layout). The
// hierarchy context menu is COMPOSED from these registered items via
// menu.draw_menu_sections — the Edit selection band (Cut..Delete) mirrors to
// its top, the GameObject creation band below — never hardcoded entries, so
// plugins extend every section the same way. Actions operate on the scene
// selection: right-click selects the row before the popup opens, so the
// clicked row is the target.

import engine "../engine"
import clip "clipboard"
import "../engine/log"
import "undo"

@(private)
_hierarchy_handle_valid :: proc(tH: engine.Transform_Handle) -> bool {
	if tH == _HANDLE_NONE do return false
	w := engine.ctx_world()
	return engine.pool_valid(&w.transforms, engine.Handle(tH))
}

// Target for create/paste actions: the active selected row, or the active
// scene's root when nothing is selected (Unity).
@(private)
_hierarchy_active_or_root :: proc() -> engine.Transform_Handle {
	active := sel_scene_active()
	if _hierarchy_handle_valid(active) do return active
	scene := engine.sm_scene_get_active()
	if scene == nil do return _HANDLE_NONE
	return engine.Transform_Handle(scene.root.handle)
}

// Any selected row that can be moved/duplicated/deleted (not a scene root,
// not inside a nested-scene instance).
// Delete is allowed on prefab-instance content: it records a removed_object on
// the instance (docs/PrefabsSpec.md §4.5), unlike rename/cut/duplicate which have
// no override representation. The scene root is never deletable.
@(private)
_hierarchy_selection_deletable :: proc() -> bool {
	for h in sel_scene_items() {
		if !_hierarchy_handle_valid(h) do continue
		if _hierarchy_handle_is_root(h) do continue
		return true
	}
	return false
}

@(private)
_hierarchy_selection_mutable :: proc() -> bool {
	for h in sel_scene_items() {
		if !_hierarchy_handle_valid(h) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		return true
	}
	return false
}

@(private)
_hierarchy_has_selection :: proc() -> bool {
	return _hierarchy_handle_valid(sel_scene_active())
}

// --- Edit: Undo / Redo -------------------------------------------------------

@(private)
_edit_can_undo :: proc() -> bool {
	if engine.application_is_playing() do return false
	s := undo.get()
	return s != nil && undo.can_undo(s)
}

@(private)
_edit_can_redo :: proc() -> bool {
	if engine.application_is_playing() do return false
	s := undo.get()
	return s != nil && undo.can_redo(s)
}

@(menu_item={path="Edit/Undo", order=-100, shortcut="Ctrl+Z", enabled=_edit_can_undo})
edit_undo_menu :: proc() {
	if s := undo.get(); s != nil do undo.apply_undo(s)
}

@(menu_item={path="Edit/Redo", order=-99, shortcut="Ctrl+Shift+Z", enabled=_edit_can_redo})
edit_redo_menu :: proc() {
	if s := undo.get(); s != nil do undo.apply_redo(s)
}

// --- Edit: selection ops (Cut..Delete band, mirrored to hierarchy popup) -----

// Pending Cut: pasting MOVES this subtree instead of inserting the clipboard
// copy (Unity). Cleared by Copy, invalidated automatically if the object dies.
@(private)
_hierarchy_cut_tH: engine.Transform_Handle

@(private)
_hierarchy_cut_pending :: proc() -> bool {
	return _hierarchy_handle_valid(_hierarchy_cut_tH) &&
		!_hierarchy_handle_is_root(_hierarchy_cut_tH) &&
		!_hierarchy_handle_is_nested(_hierarchy_cut_tH)
}

@(menu_separator={path="Edit", order=-60})
@(menu_item={path="Edit/Cut", order=-50, enabled=_hierarchy_selection_mutable})
hierarchy_cut_menu :: proc() {
	active := sel_scene_active()
	if !_hierarchy_handle_valid(active) do return
	if _hierarchy_handle_is_root(active) || _hierarchy_handle_is_nested(active) do return
	_hierarchy_cut_tH = active
}

@(menu_item={path="Edit/Copy", order=-49, enabled=_hierarchy_has_selection})
hierarchy_copy_menu :: proc() {
	active := sel_scene_active()
	if !_hierarchy_handle_valid(active) do return
	_hierarchy_cut_tH = _HANDLE_NONE
	clip.copy_hierarchy(engine.scene_copy_subtree(active))
}

@(private)
_hierarchy_can_paste :: proc() -> bool {
	target := _hierarchy_active_or_root()
	if target == _HANDLE_NONE || _hierarchy_handle_is_nested(target) do return false
	if _hierarchy_cut_pending() {
		return target != _hierarchy_cut_tH && !_is_ancestor(_hierarchy_cut_tH, target)
	}
	return clip.has_hierarchy()
}

@(menu_item={path="Edit/Paste", order=-48, enabled=_hierarchy_can_paste})
hierarchy_paste_menu :: proc() {
	if !_hierarchy_can_paste() do return
	target := _hierarchy_active_or_root()
	if _hierarchy_cut_pending() {
		undo.record_reparent_to(_hierarchy_cut_tH, target)
		sel_scene_only(_hierarchy_cut_tH)
		_hierarchy_cut_tH = _HANDLE_NONE
	} else {
		result := _paste_subtree_with_undo(clip.paste_hierarchy(), target)
		engine._transform_append_name_suffix(result, "_copy")
	}
	_hierarchy_force_open = target
}

@(menu_item={path="Edit/Duplicate", order=-47, enabled=_hierarchy_selection_mutable})
hierarchy_duplicate_menu :: proc() {
	_duplicate_selected()
}

@(private)
_hierarchy_can_rename :: proc() -> bool {
	active := sel_scene_active()
	return _hierarchy_handle_valid(active) && !_hierarchy_handle_is_nested(active)
}

@(menu_item={path="Edit/Rename", order=-46, enabled=_hierarchy_can_rename})
hierarchy_rename_menu :: proc() {
	if !_hierarchy_can_rename() do return
	_begin_rename(sel_scene_active())
}

@(menu_separator={path="Edit", order=-40})
@(menu_item={path="Edit/Delete", order=-45, enabled=_hierarchy_selection_deletable})
hierarchy_delete_menu :: proc() {
	if _hierarchy_rename_target != _HANDLE_NONE && sel_scene_is(_hierarchy_rename_target) {
		_hierarchy_rename_target = _HANDLE_NONE
	}
	if _hierarchy_cut_tH != _HANDLE_NONE && sel_scene_is(_hierarchy_cut_tH) {
		_hierarchy_cut_tH = _HANDLE_NONE
	}
	_delete_selected()
}

// --- GameObject creation band (shared: menu bar + hierarchy popup) -----------

@(menu_item={path="GameObject/Create Empty", order=-100})
hierarchy_create_empty_menu :: proc() {
	scene := engine.sm_scene_get_active()
	if scene == nil {
		// Every GameObject create targets the ACTIVE scene. No scene loaded =
		// no target, so the item is a no-op with nothing on screen to explain
		// it. sm_scene_get_active returns nil when the scene manager holds zero
		// loaded scenes, which is what a failed startup restore looks like.
		log.error("[GameObject/Create Empty] aborted: no active scene. Nothing was created.")
		_log_scene_manager_state()
		return
	}
	root := engine.Transform_Handle(scene.root.handle)
	if !_hierarchy_handle_valid(root) {
		log.errorf("[GameObject/Create Empty] aborted: active scene %q has an invalid root handle (%v). Nothing was created.", scene.path, root)
		return
	}
	tH := undo.record_create_child("Transform", root)
	if tH == _HANDLE_NONE {
		log.error("[GameObject/Create Empty] transform_new returned a null handle. Nothing was created.")
		return
	}
	log.infof("[GameObject/Create Empty] created transform %v under root %v of scene %q", tH, root, scene.path)
}

// Why sm_scene_get_active() said nil: it guards on `active_scene` against
// `count`, so a zero count rejects even a valid index. Printing both separates
// "nothing loaded" from "loaded but nothing marked active".
@(private)
_log_scene_manager_state :: proc() {
	sm := engine.ctx_scene_manager()
	if sm == nil {
		log.error("[scene] scene manager is nil (user context not initialized)")
		return
	}
	log.warningf("[scene] scene_manager: loaded_count=%d active_scene_index=%d", sm.count, sm.active_scene)
	if sm.count == 0 {
		log.warning("[scene] no scenes are loaded — the startup restore found none to open. Check the '[startup]' lines above for the working directory and asset db counts, then open a scene from the Project view or File ▸ New Scene.")
	}
}

@(private)
// Creating a child under prefab-instance content is representable as an
// added_object, so nested targets are allowed here.
_hierarchy_can_create_child :: proc() -> bool {
	active := sel_scene_active()
	if !_hierarchy_handle_valid(active) do return engine.sm_scene_get_active() != nil
	return true
}

@(menu_item={path="GameObject/Create Empty Child", order=-99, enabled=_hierarchy_can_create_child})
hierarchy_create_empty_child_menu :: proc() {
	parent := _hierarchy_active_or_root()
	if parent == _HANDLE_NONE do return
	// A child under prefab content is an added_object on the instance
	// (docs/PrefabsSpec.md §4.4) — the capture pass picks it up on save.
	sel_scene_only(undo.record_create_child("Transform", parent))
	_hierarchy_force_open = parent
}

@(private)
_hierarchy_can_create_parent :: proc() -> bool {
	active := sel_scene_active()
	return _hierarchy_handle_valid(active) && !_hierarchy_handle_is_root(active) && !_hierarchy_handle_is_nested(active)
}

@(menu_item={path="GameObject/Create Empty Parent", order=-98, enabled=_hierarchy_can_create_parent})
hierarchy_create_empty_parent_menu :: proc() {
	if !_hierarchy_can_create_parent() do return
	_create_empty_parent(sel_scene_active())
}
