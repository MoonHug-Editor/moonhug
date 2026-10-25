package session

// The confirmation before a Discard, for every place that offers one: a
// view's tab menu and the Hierarchy's scene menu. Discard cannot be undone,
// so it always asks.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "moonhug:editor/widgets"

// The document the open confirmation is about, found again when the person
// answers: it may have been saved, closed or discarded meanwhile.
@(private = "file")
_asked: struct {
	owner:  string, // owned
	key:    rawptr,
	path:   string, // owned
}

// Asks before dropping `d`'s unsaved edits, and drops them on Discard.
document_discard_ask :: proc(d: Document) {
	if !d.dirty || !d.can_discard do return
	context.allocator = runtime.default_allocator()
	delete(_asked.owner)
	delete(_asked.path)
	_asked = {owner = strings.clone(document_owner_name(d)), key = d.key, path = strings.clone(d.path)}
	// Enter discards, Escape cancels.
	buttons := []widgets.Dialog_Button{
		{label = "Discard", action = _discard_confirmed, is_default = true},
		{label = "Cancel", is_cancel = true},
	}
	widgets.dialog_open({
		title       = "Discard",
		description = fmt.tprintf("Discard \"%s\" changes?\nAll unsaved changes will be lost.", document_name(d)),
		buttons     = buttons,
	})
}

@(private = "file")
_discard_confirmed :: proc() {
	d, ok := document_find(_asked.owner, _asked.key)
	if ok && d.path == _asked.path do document_discard(d)
}
