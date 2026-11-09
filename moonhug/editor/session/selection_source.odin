package session

// The shell state the engine's tools and windows read and change: the scene
// selection, what the inspector shows, the Project window's active path and folder,
// and the Game window's aspect. The editor owns all of it and sets this at start.

import core "moonhug:libs/core"
import "base:runtime"
import "moonhug:editor/provider"

// Every field may be nil: with no source nothing is selected and the camera
// frustum uses 16:9.
Selection_Source :: struct {
	// The selected objects, in selection order.
	selection:        proc() -> []core.Transform_Handle,
	// The selection minus objects with a selected ancestor. Temp-allocated.
	top_level:        proc() -> []core.Transform_Handle,
	// The active object (the last selected one still alive), or {}.
	active:           proc() -> core.Transform_Handle,
	// The Game window's aspect ratio, false while it has no render target.
	game_aspect:      proc() -> (f32, bool),
	// Selection edits. `select_only` replaces the selection, `select_add` and
	// `select_toggle` keep the rest, `select_clear` empties it.
	select_only:      proc(tH: core.Transform_Handle),
	select_add:       proc(tH: core.Transform_Handle),
	select_toggle:    proc(tH: core.Transform_Handle),
	select_clear:     proc(),
	is_selected:      proc(tH: core.Transform_Handle) -> bool,
	// Drops handles whose objects no longer exist.
	prune:            proc(),
	// What window `window` shows (its key), through its lock (window_lock.odin):
	// the objects and assets its lock holds, or the selection, kept items
	// included. Whether it is locked, lock or unlock it, and whether its lock
	// holds nothing that resolves now.
	window_objects:      proc(window: string) -> []core.Transform_Handle,
	window_object:       proc(window: string) -> core.Transform_Handle,
	window_assets:       proc(window: string) -> []Window_Asset,
	window_locked:       proc(window: string) -> bool,
	window_lock_set:     proc(window: string, locked: bool),
	window_lock_missing: proc(window: string) -> bool,
	// The Scene window frames the selection.
	frame_selected:   proc(),
	// The Project window's active path, "" when none.
	project_active:   proc() -> string,
	// The folder the Project window shows, where Assets/Create writes.
	project_dir:      proc() -> string,
}

@(private) _selection_source: Selection_Source

@(init)
_register_selection_source :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Selection_Source", &_selection_source)
}

set_selection_source :: proc(s: Selection_Source) {
	_selection_source = s
}

selection :: proc() -> []core.Transform_Handle {
	if _selection_source.selection == nil do return {}
	return _selection_source.selection()
}

top_level :: proc() -> []core.Transform_Handle {
	if _selection_source.top_level == nil do return {}
	return _selection_source.top_level()
}

active :: proc() -> core.Transform_Handle {
	if _selection_source.active == nil do return {}
	return _selection_source.active()
}

game_aspect :: proc() -> (f32, bool) {
	if _selection_source.game_aspect == nil do return 0, false
	return _selection_source.game_aspect()
}

select_only :: proc(tH: core.Transform_Handle) {
	if _selection_source.select_only != nil do _selection_source.select_only(tH)
}

select_add :: proc(tH: core.Transform_Handle) {
	if _selection_source.select_add != nil do _selection_source.select_add(tH)
}

select_toggle :: proc(tH: core.Transform_Handle) {
	if _selection_source.select_toggle != nil do _selection_source.select_toggle(tH)
}

select_clear :: proc() {
	if _selection_source.select_clear != nil do _selection_source.select_clear()
}

is_selected :: proc(tH: core.Transform_Handle) -> bool {
	if _selection_source.is_selected == nil do return false
	return _selection_source.is_selected(tH)
}

prune :: proc() {
	if _selection_source.prune != nil do _selection_source.prune()
}

frame_selected :: proc() {
	if _selection_source.frame_selected != nil do _selection_source.frame_selected()
}

project_active :: proc() -> string {
	if _selection_source.project_active == nil do return ""
	return _selection_source.project_active()
}

project_dir :: proc() -> string {
	if _selection_source.project_dir == nil do return ""
	return _selection_source.project_dir()
}
