package quick_help

// The drawer of the Quick Help settings tab's tool list
// (keymap.Quick_Help_Settings). A package of its own: the settings type
// carries decor tags, so its package is imported by the inspector's
// generated decorators and cannot import the inspector itself.

import "base:runtime"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/keymap"

// One checkbox per tool keymap that has quick help, checked when it is
// hidden. A name in the list whose keymap is not registered, a plugin that is
// off, stays in the list. The checkboxes are sub-rows of the one value, so a
// click records as one edit of the list, with undo.
@(property_drawer={type = keymap.Quick_Help_Hidden})
property_drawer_Quick_Help_Hidden :: proc(ctx: ^inspector.Ctx) {
	row := inspector.edit_as_one_begin(ctx)
	defer inspector.edit_as_one_end(ctx, &row)
	// After edit_as_one_begin: a driven row redirects ctx.ptr.
	hidden := (^keymap.Quick_Help_Hidden)(ctx.ptr)
	im.TextUnformatted(ctx.label)
	im.Indent()
	defer im.Unindent()
	listed := false
	for km in keymap.keymaps() {
		if !km.modal || len(keymap.quick_help(km)) == 0 do continue
		listed = true
		name := strings.clone_to_cstring(km.name, context.temp_allocator)
		on := slice.contains(hidden[:], km.name)
		im.PushID(name)
		if im.Checkbox(inspector.field_row(name), &on) do _set_hidden(hidden, km.name, on)
		im.PopID()
	}
	if !listed do im.TextDisabled("No tool keymap has quick help")
}

// The list holds the settings file's strings, so it grows and shrinks on the
// default allocator.
@(private = "file")
_set_hidden :: proc(hidden: ^keymap.Quick_Help_Hidden, name: string, on: bool) {
	context.allocator = runtime.default_allocator()
	at, found := slice.linear_search(hidden[:], name)
	switch {
	case on && !found:
		append(hidden, strings.clone(name))
	case !on && found:
		delete(hidden[at])
		ordered_remove(hidden, at)
	}
}
