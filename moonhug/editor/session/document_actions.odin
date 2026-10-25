package session

import "base:runtime"
import "moonhug:editor/provider"

// The scenes the installed engine has open, as the shell's session and run
// code sees them. The engine installs the procs
// (plugins/engine/editor/scene_tools/document_actions.odin). With none
// installed there are no open scenes. Saving goes through the open documents
// (documents.odin), which cover scenes and every other kind of file.

Document_Actions :: struct {
	// Paths of the open documents that live in a file, temp-allocated.
	open_paths:      proc() -> []string,
	// The active document's path and its live state serialized, for a run that
	// plays unsaved edits. `data` is owned by the caller, nil when it does not
	// serialize. ok is false when no document is open.
	snapshot_active: proc() -> (path: string, data: []byte, ok: bool),
	// The active document's path. ok is false when no document is active.
	active_path:     proc() -> (path: string, ok: bool),
}

@(private) _document_actions: Document_Actions

@(init)
_register_document_actions :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Document_Actions", &_document_actions)
}

set_document_actions :: proc(a: Document_Actions) {
	_document_actions = a
}

document_open_paths :: proc() -> []string {
	if _document_actions.open_paths == nil do return {}
	return _document_actions.open_paths()
}

document_snapshot_active :: proc() -> (path: string, data: []byte, ok: bool) {
	if _document_actions.snapshot_active == nil do return "", nil, false
	return _document_actions.snapshot_active()
}

document_active_path :: proc() -> (path: string, ok: bool) {
	if _document_actions.active_path == nil do return "", false
	return _document_actions.active_path()
}
