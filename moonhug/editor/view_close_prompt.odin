package editor

// A view that holds an editor's working copy (inspector/asset_doc_copies.odin)
// asks before it closes with unapplied edits: Apply, Discard, or Cancel to keep
// it open. Closing loses the copy, unlike a view of a shared document, whose
// edits stay in the document. Installed as the window registry's close guard,
// so the close button and the tab menu's Close Tab both ask.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"

// The view the open question is about, found again when it is answered.
@(private = "file")
_asked: string // owned

// True keeps the view open: it holds unapplied edits, and the question is up.
view_close_guard :: proc(w: ^wnd.Window) -> bool {
	if workspace_view_close_guard(w) do return true
	d, ok := session.view_document(w.key)
	if !ok || d.view != w.key || !d.dirty do return false
	context.allocator = runtime.default_allocator()
	delete(_asked)
	_asked = strings.clone(w.key)
	// Enter applies, Escape cancels.
	buttons := []widgets.Dialog_Button{
		{label = "Apply", action = _close_apply, is_default = true},
		{label = "Discard", action = _close_discard},
		{label = "Cancel", is_cancel = true},
	}
	widgets.dialog_open({
		title       = "Unapplied Changes",
		description = fmt.tprintf("Apply \"%s\" changes before closing?\nDiscard loses them.", session.document_name(d)),
		buttons     = buttons,
	})
	return true
}

@(private = "file")
_close_apply :: proc() {
	d, ok := session.view_document(_asked)
	if ok && d.view == _asked && !session.document_save(d) do return
	wnd.close(_asked)
}

@(private = "file")
_close_discard :: proc() {
	if d, ok := session.view_document(_asked); ok && d.view == _asked do session.document_discard(d)
	wnd.close(_asked)
}
