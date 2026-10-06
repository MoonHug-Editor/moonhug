package scene_views

// The Edit menu's scene selection ops and the GameObject create items. The
// hierarchy context menu is COMPOSED from the registered menu items via
// menu.draw_menu_sections — the Edit selection band (Cut..Delete) mirrors to
// its top, the GameObject creation band below — never hardcoded entries, so
// plugins extend every section the same way. Actions operate on the scene
// selection: right-click selects the row before the popup opens, so the
// clicked row is the target.

import engine "moonhug:packages/engine"
import clip "moonhug:editor/clipboard"
import "moonhug:editor/viewport"
import undo "moonhug:packages/engine/editor/undo"

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
	active := viewport.active()
	if _hierarchy_handle_valid(active) do return active
	scene := engine.sm_scene_get_active()
	if scene == nil do return _HANDLE_NONE
	return engine.Transform_Handle(scene.root.handle)
}

// Any selected row that can be moved/duplicated/deleted (not a scene root,
// not inside a nested-scene instance).
// Delete is allowed on prefab-instance content: it records a removed_object on
// the instance (plugins/engine/docs/PrefabsSpec.md §4.5), unlike rename/cut/duplicate which have
// no override representation. The scene root is never deletable.
@(private)
_hierarchy_selection_deletable :: proc() -> bool {
	for h in viewport.selection() {
		if !_hierarchy_handle_valid(h) do continue
		if _hierarchy_handle_is_root(h) do continue
		return true
	}
	return false
}

@(private)
_hierarchy_selection_mutable :: proc() -> bool {
	for h in viewport.selection() {
		if !_hierarchy_handle_valid(h) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		return true
	}
	return false
}

@(private)
_hierarchy_has_selection :: proc() -> bool {
	return _hierarchy_handle_valid(viewport.active())
}

// --- Edit: selection ops (Cut..Delete band, mirrored to hierarchy popup) -----
// The shell's Edit menu (editor/edit_menu.odin) acts on the project selection
// or calls these through viewport.Scene_Views.

// Pending Cut: pasting MOVES this subtree instead of inserting the clipboard
// copy. Cleared by Copy, invalidated automatically if the object dies.
@(private)
_hierarchy_cut_tH: engine.Transform_Handle

@(private)
_hierarchy_cut_pending :: proc() -> bool {
	return _hierarchy_handle_valid(_hierarchy_cut_tH) &&
		!_hierarchy_handle_is_root(_hierarchy_cut_tH) &&
		!_hierarchy_handle_is_nested(_hierarchy_cut_tH)
}

// Whether the Edit menu's `op` applies to the scene selection.
edit_can :: proc(op: viewport.Edit_Op) -> bool {
	switch op {
	case .Cut, .Duplicate: return _hierarchy_selection_mutable()
	case .Copy:            return _hierarchy_has_selection()
	case .Paste:           return _hierarchy_can_paste()
	case .Rename:          return _hierarchy_can_rename()
	case .Delete:          return _hierarchy_selection_deletable()
	}
	return false
}

// Runs the Edit menu's `op` on the scene selection.
edit_run :: proc(op: viewport.Edit_Op) {
	switch op {
	case .Cut:       _hierarchy_cut()
	case .Copy:      _hierarchy_copy()
	case .Paste:     _hierarchy_paste()
	case .Duplicate: _duplicate_selected()
	case .Rename:    _hierarchy_rename()
	case .Delete:    _hierarchy_delete()
	}
}

@(private = "file")
_hierarchy_cut :: proc() {
	active := viewport.active()
	if !_hierarchy_handle_valid(active) do return
	if _hierarchy_handle_is_root(active) || _hierarchy_handle_is_nested(active) do return
	_hierarchy_cut_tH = active
}

@(private = "file")
_hierarchy_copy :: proc() {
	active := viewport.active()
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

@(private = "file")
_hierarchy_paste :: proc() {
	if !_hierarchy_can_paste() do return
	target := _hierarchy_active_or_root()
	// The pasted or moved object becomes the selection. The tracker attaches
	// that to the paste's own undo step, so one undo also restores what was
	// selected before.
	if _hierarchy_cut_pending() {
		undo.record_reparent_to(_hierarchy_cut_tH, target)
		viewport.select_only(_hierarchy_cut_tH)
		_hierarchy_cut_tH = _HANDLE_NONE
	} else {
		result := _paste_subtree_with_undo(clip.paste_hierarchy(), target)
		engine._transform_append_name_suffix(result, "_copy")
		if result != _HANDLE_NONE do viewport.select_only(result)
	}
	_hierarchy_force_open = target
}

@(private)
_hierarchy_can_rename :: proc() -> bool {
	active := viewport.active()
	return _hierarchy_handle_valid(active) && !_hierarchy_handle_is_nested(active)
}

@(private = "file")
_hierarchy_rename :: proc() {
	if !_hierarchy_can_rename() do return
	_begin_rename(viewport.active())
}

@(private = "file")
_hierarchy_delete :: proc() {
	if _hierarchy_rename_target != _HANDLE_NONE && viewport.is_selected(_hierarchy_rename_target) {
		_hierarchy_rename_target = _HANDLE_NONE
	}
	if _hierarchy_cut_tH != _HANDLE_NONE && viewport.is_selected(_hierarchy_cut_tH) {
		_hierarchy_cut_tH = _HANDLE_NONE
	}
	_delete_selected()
}

// --- GameObject creation band (shared: menu bar + hierarchy popup) -----------

@(menu_item={path="GameObject/Create Empty", order=-100})
hierarchy_create_empty_menu :: proc() {
	scene := engine.sm_scene_get_active()
	if scene == nil do return
	// What was made becomes the selection, in the create's own undo step
	// (the selection tracker attaches it).
	viewport.select_only(undo.record_create_child("Transform", engine.Transform_Handle(scene.root.handle)))
}

// Creating a child under prefab-instance content is representable as an
// added_object, so nested targets are allowed here.
_hierarchy_can_create_child :: proc() -> bool {
	active := viewport.active()
	if !_hierarchy_handle_valid(active) do return engine.sm_scene_get_active() != nil
	return true
}

@(menu_item={path="GameObject/Create Empty Child", order=-99, enabled=_hierarchy_can_create_child})
hierarchy_create_empty_child_menu :: proc() {
	parent := _hierarchy_active_or_root()
	if parent == _HANDLE_NONE do return
	// A child under prefab content is an added_object on the instance
	// (plugins/engine/docs/PrefabsSpec.md §4.4) — the capture pass picks it up on save.
	viewport.select_only(undo.record_create_child("Transform", parent))
	_hierarchy_force_open = parent
}

_hierarchy_can_create_parent :: proc() -> bool {
	active := viewport.active()
	return _hierarchy_handle_valid(active) && !_hierarchy_handle_is_root(active) && !_hierarchy_handle_is_nested(active)
}

@(menu_item={path="GameObject/Create Empty Parent", order=-98, enabled=_hierarchy_can_create_parent})
hierarchy_create_empty_parent_menu :: proc() {
	if !_hierarchy_can_create_parent() do return
	_create_empty_parent(viewport.active())
}
