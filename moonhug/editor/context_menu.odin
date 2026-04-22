package editor

import "../engine"

ContextMenuAction :: proc(comp_ptr: rawptr)

ContextMenuEntry :: struct {
	label: string,
	action: ContextMenuAction,
}

_context_menu_registry: map[engine.TypeKey][dynamic]ContextMenuEntry

_shutdown_context_menu_registry :: proc() {
	for _, v in _context_menu_registry {
		delete(v)
	}
	delete(_context_menu_registry)
}

