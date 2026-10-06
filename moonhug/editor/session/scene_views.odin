package session

// The engine's scene views as the shell calls them: the Hierarchy and the
// Inspector windows, their menus, the Edit menu's scene half, and the
// hierarchy state the selection undo and the scene opening reach. The engine
// installs the procs (plugins/engine/editor/scene_views/install.odin). With
// none installed the windows do not draw and the Edit menu acts on the
// project only.

import core "moonhug:host/core"
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

Scene_Views :: struct {
	draw_hierarchy:       proc(),
	draw_inspector:       proc(),
	// The Component menu and the components' overflow menu entries, once the menus exist.
	register_menus:       proc(),
	shutdown:             proc(),
	// The Edit menu on the scene selection.
	edit_can:             proc(op: Edit_Op) -> bool,
	edit_run:             proc(op: Edit_Op),
	// Forgets the nested scenes entered from the hierarchy, before another scene opens.
	edit_stack_clear:     proc(),
	// Unfolds every ancestor of `tH` in the hierarchy.
	reveal:               proc(tH: core.Transform_Handle),
	// Scrolls the hierarchy to the selection next frame.
	scroll_to_selection:  proc(),
	// Applies a select request posted this frame (core.inspector_request_select).
	apply_pending_select: proc(),
	// A hierarchy row is being renamed: the rename gate the input debug view shows.
	rename_active:        proc() -> bool,
	// Clears the hierarchy's keyboard gates (the input debug view's rescue button).
	reset_input_gates:    proc(),
}

@(private) _scene_views: Scene_Views

@(init)
_register_scene_views :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Scene_Views", &_scene_views)
}

set_scene_views :: proc(v: Scene_Views) {
	_scene_views = v
}

hierarchy_draw :: proc() {
	if _scene_views.draw_hierarchy != nil do _scene_views.draw_hierarchy()
}

inspector_draw :: proc() {
	if _scene_views.draw_inspector != nil do _scene_views.draw_inspector()
}

scene_views_register_menus :: proc() {
	if _scene_views.register_menus != nil do _scene_views.register_menus()
}

scene_views_shutdown :: proc() {
	if _scene_views.shutdown != nil do _scene_views.shutdown()
}

edit_can :: proc(op: Edit_Op) -> bool {
	if _scene_views.edit_can == nil do return false
	return _scene_views.edit_can(op)
}

edit_run :: proc(op: Edit_Op) {
	if _scene_views.edit_run != nil do _scene_views.edit_run(op)
}

edit_stack_clear :: proc() {
	if _scene_views.edit_stack_clear != nil do _scene_views.edit_stack_clear()
}

hierarchy_reveal :: proc(tH: core.Transform_Handle) {
	if _scene_views.reveal != nil do _scene_views.reveal(tH)
}

hierarchy_scroll_to_selection :: proc() {
	if _scene_views.scroll_to_selection != nil do _scene_views.scroll_to_selection()
}

apply_pending_select :: proc() {
	if _scene_views.apply_pending_select != nil do _scene_views.apply_pending_select()
}

hierarchy_rename_active :: proc() -> bool {
	if _scene_views.rename_active == nil do return false
	return _scene_views.rename_active()
}

reset_input_gates :: proc() {
	if _scene_views.reset_input_gates != nil do _scene_views.reset_input_gates()
}
