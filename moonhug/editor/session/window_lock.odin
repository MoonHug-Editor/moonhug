package session

// What a window shows, through its lock: the editor's window_lock.odin holds the
// locks, and these reach it. Every window that declares a lock
// (@(editor_window) lock="instance" or lock="shared") gets a padlock in its
// tab bar from the shell, and reads what to show from here:
//
//   window_objects / window_object   the scene objects, or the one acted on
//   window_assets / window_asset     the project assets, or the one acted on
//
// Unlocked, these are the selection, the items kept while the other set is
// selected included. Locked, they are what the lock holds and resolves now,
// which may be nothing for a while (window_lock_missing): the window says so
// with window_lock_missing_note, and shows its target again when it is back.

import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"

// An asset a window shows: its path and the selected sub-asset, 0 for the
// asset itself.
Window_Asset :: struct {
	path:   string,
	sub_id: core.Local_ID,
}

window_objects :: proc(window: string) -> []core.Transform_Handle {
	if _selection_source.window_objects == nil do return {}
	return _selection_source.window_objects(window)
}

window_object :: proc(window: string) -> core.Transform_Handle {
	if _selection_source.window_object == nil do return {}
	return _selection_source.window_object(window)
}

window_assets :: proc(window: string) -> []Window_Asset {
	if _selection_source.window_assets == nil do return {}
	return _selection_source.window_assets(window)
}

// The asset window `window` acts on: the last of its assets. {} when none.
window_asset :: proc(window: string) -> Window_Asset {
	a := window_assets(window)
	if len(a) == 0 do return {}
	return a[len(a) - 1]
}

window_locked :: proc(window: string) -> bool {
	if _selection_source.window_locked == nil do return false
	return _selection_source.window_locked(window)
}

// Locks window `window` to the selection as it is now, or unlocks it to follow
// the selection again. With nothing selected the window stays unlocked.
window_lock_set :: proc(window: string, locked: bool) {
	if _selection_source.window_lock_set != nil do _selection_source.window_lock_set(window, locked)
}

// Whether window `window` is locked and nothing its lock holds is here now: its
// scene is closed, or it was deleted.
window_lock_missing :: proc(window: string) -> bool {
	if _selection_source.window_lock_missing == nil do return false
	return _selection_source.window_lock_missing(window)
}

// Draws the note of a locked window whose target is not here, and returns
// true, or returns false when there is nothing to say. A window calls it where
// it would draw its target and stops when it returns true.
window_lock_missing_note :: proc(window: string) -> bool {
	if !window_lock_missing(window) do return false
	im.TextDisabled("Locked to something that is not here now")
	im.TextWrapped("Its scene is closed or it was deleted. The window shows it again when it is back. Unlock to follow the selection.")
	return true
}

// The padlock of window `window`, which the shell draws first in the tab bar of
// a window that declares a lock: open while the window follows the
// selection, closed while it is locked. A click locks it to the selection or
// unlocks it. Returns whether the click changed the lock, and the lock now.
window_lock_button :: proc(window: string) -> (changed, locked: bool) {
	was := window_locked(window)
	locked = was
	widgets.toggle_button(was ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN, &locked)
	widgets.tooltip(was ? "Unlock: follow the selection again" : "Lock to the current selection")
	if locked == was do return false, was
	window_lock_set(window, locked)
	locked = window_locked(window)
	return locked != was, locked
}
