package inspector

// Items a package adds to an inspected object's overflow menu, the menu
// button on its header: a component in the hierarchy inspector today, any
// inspected type the inspector hands its pointer to. Registered by typeid
// from the generated init_context_menu_registry.

import "base:runtime"

Context_Menu_Action :: proc(ptr: rawptr)

// Adds an item to the overflow menu of every inspected object of a type.
//
// `type` is the type, `menu` the item's label and `order` its place. The
// proc takes the object as a rawptr.
@(extension_point={attribute="context_menu", target="proc", fields="type menu order"})
Context_Menu_Entry :: struct {
	label:  string,
	action: Context_Menu_Action,
	// The @(context_menu) that created the entry, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug
	// tooltips on.
	origin: string,
}

@(private) _context_menu_registry: map[typeid][dynamic]Context_Menu_Entry

// Items register in generated order, the attribute's `order` first.
context_menu_add :: proc(tid: typeid, entry: Context_Menu_Entry) {
	context.allocator = runtime.default_allocator()
	if tid not_in _context_menu_registry do _context_menu_registry[tid] = make([dynamic]Context_Menu_Entry)
	append(&_context_menu_registry[tid], entry)
}

// The items for a type, in order. Empty when none.
context_menu_entries :: proc(tid: typeid) -> []Context_Menu_Entry {
	if entries, ok := _context_menu_registry[tid]; ok do return entries[:]
	return {}
}

@(private)
_shutdown_context_menu_registry :: proc() {
	for _, v in _context_menu_registry do delete(v)
	delete(_context_menu_registry)
	_context_menu_registry = {}
}
