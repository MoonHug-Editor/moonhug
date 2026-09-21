package editor

import "../engine"

ContextMenuAction :: proc(comp_ptr: rawptr)

ContextMenuEntry :: struct {
	label: string,
	action: ContextMenuAction,
	// The @(context_menu) that created the entry, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug tooltips on.
	origin: string,
}

_context_menu_registry: map[engine.TypeKey][dynamic]ContextMenuEntry

_shutdown_context_menu_registry :: proc() {
	for _, v in _context_menu_registry {
		delete(v)
	}
	delete(_context_menu_registry)
}

