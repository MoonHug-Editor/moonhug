package session

// The engine's Scene windows as the shell calls them: the Hierarchy and the
// Inspector windows, their menus, the Edit menu's scene half, and the
// hierarchy state the selection undo and the scene opening reach. The engine
// installs the procs (plugins/engine/editor/scene_windows/install.odin). With
// none installed the windows do not draw and the Edit menu acts on the
// project only.

import core "moonhug:libs/core"
import "base:runtime"
import "moonhug:editor/provider"

// The Edit menu's selection operations.
Edit_Op :: enum {
	Cut,
	Copy,
	Paste,
	Duplicate,
	Rename,
	Delete,
}

Scene_Windows :: struct {
	// The Scene windows' per-frame bookkeeping, run every frame whether or not
	// a window is visible (the windows themselves draw as window instances).
	frame_begin:          proc(),
	// The Component menu and the components' overflow menu entries, once the menus exist.
	register_menus:       proc(),
	shutdown:             proc(),
	// The Edit menu on the scene selection.
	edit_can:             proc(op: Edit_Op) -> bool,
	edit_run:             proc(op: Edit_Op),
	// Forgets the nested scenes entered from the hierarchy, before another scene opens.
	edit_stack_clear:     proc(),
	// Unfolds every ancestor of `tH` in every hierarchy copy.
	reveal:               proc(tH: core.Transform_Handle),
	// Scrolls every hierarchy copy to the selection next frame.
	scroll_to_selection:  proc(),
	// Applies a select request posted this frame (core.inspector_request_select).
	apply_pending_select: proc(),
	// A hierarchy row is being renamed: the rename gate the Input Debug window shows.
	rename_active:        proc() -> bool,
	// Clears the hierarchy's keyboard gates (the Input Debug window's rescue button).
	reset_input_gates:    proc(),
}

@(private) _scene_windows: Scene_Windows

@(init)
_register_scene_windows :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Scene_Windows", &_scene_windows)
}

set_scene_windows :: proc(v: Scene_Windows) {
	_scene_windows = v
}

scene_windows_frame_begin :: proc() {
	if _scene_windows.frame_begin != nil do _scene_windows.frame_begin()
}

scene_windows_register_menus :: proc() {
	if _scene_windows.register_menus != nil do _scene_windows.register_menus()
}

scene_windows_shutdown :: proc() {
	if _scene_windows.shutdown != nil do _scene_windows.shutdown()
}

edit_can :: proc(op: Edit_Op) -> bool {
	if _scene_windows.edit_can == nil do return false
	return _scene_windows.edit_can(op)
}

edit_run :: proc(op: Edit_Op) {
	if _scene_windows.edit_run != nil do _scene_windows.edit_run(op)
}

edit_stack_clear :: proc() {
	if _scene_windows.edit_stack_clear != nil do _scene_windows.edit_stack_clear()
}

hierarchy_reveal :: proc(tH: core.Transform_Handle) {
	if _scene_windows.reveal != nil do _scene_windows.reveal(tH)
}

hierarchy_scroll_to_selection :: proc() {
	if _scene_windows.scroll_to_selection != nil do _scene_windows.scroll_to_selection()
}

apply_pending_select :: proc() {
	if _scene_windows.apply_pending_select != nil do _scene_windows.apply_pending_select()
}

hierarchy_rename_active :: proc() -> bool {
	if _scene_windows.rename_active == nil do return false
	return _scene_windows.rename_active()
}

reset_input_gates :: proc() {
	if _scene_windows.reset_input_gates != nil do _scene_windows.reset_input_gates()
}
