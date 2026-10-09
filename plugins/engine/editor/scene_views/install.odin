package scene_views

// The engine's scene views behind the shell's session.Scene_Views: the
// Hierarchy and Inspector windows, the Component menu, the Edit menu's scene
// half and the hierarchy state the shell reaches. Installed through
// @(provider_install).

import "moonhug:editor/session"
// Links the engine's boot and shutdown (session.Host_Lifecycle), which
// installs itself from @(init) and has no generated entry point of its own.

@(provider_install)
install_scene_views :: proc() {
	session.set_scene_views({
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

@(private = "file")
_register_menus :: proc() {
	register_component_menus()
}

@(private = "file")
_shutdown :: proc() {
	shutdown_hierarchy_views()
}
