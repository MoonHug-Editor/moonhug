package editor

// Quitting with unsaved files asks first: Save All, Don't Save or Cancel.
// Every way out comes through quit_gate: File ▸ Quit, the window's close
// button, the system's quit, and a Relaunch whose build is ready
// (relaunch.odin). Don't Save quits without writing anything, the same final
// answer as a Discard.

import "core:fmt"
import "core:strings"
import "menu"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

// Set by an answer that lets the quit through.
@(private = "file")
_quit_confirmed: bool

// The most files the prompt names before it says how many more.
@(private = "file")
_QUIT_PROMPT_NAMES :: 8

// Whether the editor quits now. A quit request while files have unsaved
// changes is held, and the prompt asks what to do with them.
quit_gate :: proc() -> bool {
	if !menu.quit_requested && !gfx.quit_requested() do return false
	if _quit_confirmed do return true
	dirty := session.documents_dirty()
	if len(dirty) == 0 do return true
	menu.quit_requested = false
	gfx.cancel_quit()
	_quit_ask(dirty)
	return false
}

@(private = "file")
_quit_ask :: proc(dirty: []session.Document) {
	verb := "relaunching" if relaunch_quitting() else "quitting"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d file%s with unsaved changes:", len(dirty), "" if len(dirty) == 1 else "s")
	for d, i in dirty {
		if i == _QUIT_PROMPT_NAMES {
			fmt.sbprintf(&b, "\n  and %d more", len(dirty) - i)
			break
		}
		fmt.sbprintf(&b, "\n  %s", session.document_name(d))
	}
	buttons := []widgets.Dialog_Button{
		{label = "Save All", action = _quit_save_all, is_default = true},
		{label = "Don't Save", action = _quit_without_saving},
		{label = "Cancel", action = _quit_cancel, is_cancel = true},
	}
	widgets.dialog_open({title = fmt.tprintf("Save changes before %s?", verb), description = strings.to_string(b), buttons = buttons})
}

// Saves every file, and quits once all of them are written. One that could
// not be written keeps the editor open with the reason in the console.
@(private = "file")
_quit_save_all :: proc() {
	_, failed := session.documents_save_all()
	if failed > 0 {
		log.errorf("[Quit] %d file%s could not be saved, the editor stays open", failed, "" if failed == 1 else "s")
		relaunch_quit_cancelled()
		return
	}
	_quit_confirmed = true
	menu.quit_requested = true
}

@(private = "file")
_quit_without_saving :: proc() {
	_quit_confirmed = true
	menu.quit_requested = true
}

@(private = "file")
_quit_cancel :: proc() {
	relaunch_quit_cancelled()
}
