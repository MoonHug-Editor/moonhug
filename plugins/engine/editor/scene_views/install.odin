package scene_views

// The engine's scene views behind the shell's viewport.Scene_Views: the
// Hierarchy and Inspector windows, the Component menu, the Edit menu's scene
// half and the hierarchy state the shell reaches. Installed from @(init), so
// the editor and the test binary both have it.

import "base:runtime"
import "moonhug:editor/viewport"
// Links the engine's boot and shutdown (viewport.Host_Lifecycle), which
// installs itself from @(init) and has no generated entry point of its own.
import _ "moonhug:packages/engine/editor/host"

install_scene_views :: proc() {
	viewport.set_scene_views({
		draw_hierarchy       = draw_hierarchy_view,
		draw_inspector       = draw_hierarchy_inspector,
		register_menus       = _register_menus,
		shutdown             = _shutdown,
		edit_can             = edit_can,
		edit_run             = edit_run,
		edit_stack_clear     = hierarchy_edit_stack_clear,
		reveal               = _hierarchy_open_ancestors,
		scroll_to_selection  = proc() { _hierarchy_scroll_to_sel = true },
		apply_pending_select = hierarchy_apply_pending_select,
		rename_active        = proc() -> bool { return _hierarchy_rename_target != _HANDLE_NONE },
		reset_input_gates    = proc() {
			_hierarchy_rename_target = _HANDLE_NONE
			_hierarchy_rename_just_finished = false
		},
	})
}

@(init, private = "file")
_install_scene_views :: proc "contextless" () {
	context = runtime.default_context()
	install_scene_views()
}

@(private = "file")
_register_menus :: proc() {
	_init_context_menu_registry()
	register_component_menus()
}

@(private = "file")
_shutdown :: proc() {
	_shutdown_context_menu_registry()
	shutdown_hierarchy_views()
}
