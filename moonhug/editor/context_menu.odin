package editor

import "../engine"

ContextMenuAction :: proc(comp_ptr: rawptr)

ContextMenuEntry :: struct {
	label: string,
	action: ContextMenuAction,
}

_context_menu_registry: map[engine.TypeKey][dynamic]ContextMenuEntry

