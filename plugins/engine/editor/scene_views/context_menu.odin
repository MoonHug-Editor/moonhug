package scene_views

import core "moonhug:host/core"

ContextMenuAction :: proc(comp_ptr: rawptr)

// Adds an item to a component's overflow menu, the menu button on its header
// in the inspector.
//
// `type` is the component type, `menu` the item's label and `order` its place.
// The proc takes the component as a rawptr.
@(extension_point={attribute="context_menu", target="proc", fields="type menu order"})
ContextMenuEntry :: struct {
	label: string,
	action: ContextMenuAction,
	// The @(context_menu) that created the entry, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug tooltips on.
	origin: string,
}

_context_menu_registry: map[core.TypeKey][dynamic]ContextMenuEntry

_shutdown_context_menu_registry :: proc() {
	for _, v in _context_menu_registry {
		delete(v)
	}
	delete(_context_menu_registry)
}

