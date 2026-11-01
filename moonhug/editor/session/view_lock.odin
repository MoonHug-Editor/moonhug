package session

// What a view shows, through its lock: the editor's view_lock.odin holds the
// locks, and these reach it. Every view whose window declares a lock
// (@(editor_window) lock="instance" or lock="shared") gets a padlock in its
// tab bar from the shell, and reads what to show from here:
//
//   view_objects / view_object   the scene objects, or the one acted on
//   view_assets / view_asset     the project assets, or the one acted on
//
// Unlocked, these are the selection, the items kept while the other set is
// selected included. Locked, they are what the lock holds and resolves now,
// which may be nothing for a while (view_lock_missing): the view says so
// with view_lock_missing_note, and shows its target again when it is back.

import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"

// An asset a view shows: its path and the selected sub-asset, 0 for the
// asset itself.
View_Asset :: struct {
	path:   string,
	sub_id: core.Local_ID,
}

view_objects :: proc(view: string) -> []core.Transform_Handle {
	if _selection_source.view_objects == nil do return {}
	return _selection_source.view_objects(view)
}

view_object :: proc(view: string) -> core.Transform_Handle {
	if _selection_source.view_object == nil do return {}
	return _selection_source.view_object(view)
}

view_assets :: proc(view: string) -> []View_Asset {
	if _selection_source.view_assets == nil do return {}
	return _selection_source.view_assets(view)
}

// The asset view `view` acts on: the last of its assets. {} when none.
view_asset :: proc(view: string) -> View_Asset {
	a := view_assets(view)
	if len(a) == 0 do return {}
	return a[len(a) - 1]
}

view_locked :: proc(view: string) -> bool {
	if _selection_source.view_locked == nil do return false
	return _selection_source.view_locked(view)
}

// Locks view `view` to the selection as it is now, or unlocks it to follow
// the selection again. With nothing selected the view stays unlocked.
view_lock_set :: proc(view: string, locked: bool) {
	if _selection_source.view_lock_set != nil do _selection_source.view_lock_set(view, locked)
}

// Whether view `view` is locked and nothing its lock holds is here now: its
// scene is closed, or it was deleted.
view_lock_missing :: proc(view: string) -> bool {
	if _selection_source.view_lock_missing == nil do return false
	return _selection_source.view_lock_missing(view)
}

// Draws the note of a locked view whose target is not here, and returns
// true, or returns false when there is nothing to say. A view calls it where
// it would draw its target and stops when it returns true.
view_lock_missing_note :: proc(view: string) -> bool {
	if !view_lock_missing(view) do return false
	im.TextDisabled("Locked to something that is not here now")
	im.TextWrapped("Its scene is closed or it was deleted. The view shows it again when it is back. Unlock to follow the selection.")
	return true
}

// The padlock of view `view`, which the shell draws first in the tab bar of
// a view whose window declares a lock: open while the view follows the
// selection, closed while it is locked. A click locks it to the selection or
// unlocks it. Returns whether the click changed the lock, and the lock now.
view_lock_button :: proc(view: string) -> (changed, locked: bool) {
	was := view_locked(view)
	locked = was
	widgets.toggle_button(was ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &locked)
	widgets.tooltip(was ? "Unlock: follow the selection again" : "Lock to the current selection")
	if locked == was do return false, was
	view_lock_set(view, locked)
	locked = view_locked(view)
	return locked != was, locked
}
