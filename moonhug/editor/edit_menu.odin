package editor

// The Edit menu's Undo and Redo, and its selection band (Cut..Delete). The band
// acts on the selection, wherever it is: on the selected files while the
// project holds the selection (the operations the Project window's own
// shortcuts run), on the scene objects otherwise, through the installed scene
// windows (session.Scene_Windows). The hierarchy's context menu mirrors the band
// to its top (plugins/engine/editor/scene_windows/hierarchy_menu.odin).

import "moonhug:editor/session"
import undo "moonhug:editor/undo"
import "moonhug:editor/keymap"

// --- Edit: Undo / Redo -------------------------------------------------------
// Enabled during Play too: undo.can_undo/can_redo limit a run to its own steps.

@(private)
_edit_can_undo :: proc() -> bool {
	s := undo.get()
	if s == nil || !undo.can_undo(s) do return keymap.disabled("Nothing to undo")
	return true
}

@(private)
_edit_can_redo :: proc() -> bool {
	s := undo.get()
	if s == nil || !undo.can_redo(s) do return keymap.disabled("Nothing to redo")
	return true
}

@(menu_item={path="Edit/Undo", order=-100, shortcut="Ctrl+Z", enabled=_edit_can_undo, help="Reverts the last change"})
edit_undo_menu :: proc() {
	if s := undo.get(); s != nil do undo.apply_undo(s)
}

@(menu_item={path="Edit/Redo", order=-99, shortcut="Ctrl+Shift+Z, Ctrl+Y", enabled=_edit_can_redo, help="Applies the change undo reverted last"})
edit_redo_menu :: proc() {
	if s := undo.get(); s != nil do undo.apply_redo(s)
}

// --- Edit: selection ops (Cut..Delete band, mirrored to hierarchy popup) -----

@(private)
_edit_can_cut :: proc() -> bool { return sel_in_project() || session.edit_can(.Cut) }
@(private)
_edit_can_copy :: proc() -> bool { return sel_in_project() || session.edit_can(.Copy) }
@(private)
_edit_can_paste :: proc() -> bool { return sel_in_project() ? project_ops_can_paste() : session.edit_can(.Paste) }
@(private)
_edit_can_duplicate :: proc() -> bool { return sel_in_project() || session.edit_can(.Duplicate) }
@(private)
_edit_can_rename :: proc() -> bool { return sel_in_project() ? _project_selection_renameable() : session.edit_can(.Rename) }
@(private)
_edit_can_delete :: proc() -> bool { return sel_in_project() || session.edit_can(.Delete) }

@(menu_separator={path="Edit", order=-60})
@(menu_item={path="Edit/Cut", order=-50, enabled=_edit_can_cut, help="Cuts the selected objects, or the selected files"})
hierarchy_cut_menu :: proc() {
	if sel_in_project() {
		project_ops_cut()
		return
	}
	session.edit_run(.Cut)
}

@(menu_item={path="Edit/Copy", order=-49, enabled=_edit_can_copy, help="Copies the selected objects, or the selected files"})
hierarchy_copy_menu :: proc() {
	if sel_in_project() {
		project_ops_copy()
		return
	}
	session.edit_run(.Copy)
}

@(menu_item={path="Edit/Paste", order=-48, enabled=_edit_can_paste, help="Pastes the copied objects, or the copied files"})
hierarchy_paste_menu :: proc() {
	if sel_in_project() {
		project_ops_paste()
		return
	}
	session.edit_run(.Paste)
}

@(menu_item={path="Edit/Duplicate", order=-47, enabled=_edit_can_duplicate, help="Duplicates the selected objects, or the selected files. A selected sub-asset is copied inside the file that holds it"})
hierarchy_duplicate_menu :: proc() {
	if sel_in_project() {
		project_ops_duplicate()
		return
	}
	session.edit_run(.Duplicate)
}

@(menu_item={path="Edit/Rename", order=-46, enabled=_edit_can_rename, help="Renames the selected object, or the selected file"})
hierarchy_rename_menu :: proc() {
	if sel_in_project() {
		if _project_selection_renameable() do _project_begin_rename_selected()
		return
	}
	session.edit_run(.Rename)
}

@(menu_separator={path="Edit", order=-40})
@(menu_item={path="Edit/Delete", order=-45, enabled=_edit_can_delete, help="Deletes the selected objects, or moves the selected files to the Trash"})
hierarchy_delete_menu :: proc() {
	if sel_in_project() {
		project_ops_delete()
		return
	}
	session.edit_run(.Delete)
}
