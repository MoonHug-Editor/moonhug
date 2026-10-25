package session

// Open documents: the files loaded for editing, edited or not. An owner is
// the code that holds loaded copies, not a file type, and it reports what it
// holds when asked, so nothing here can go stale. The owners:
// - scenes, the scene manager's (plugins/engine/editor/scene_views/scene_documents.odin)
// - asset documents, the inspector's, every serialized asset type
//   (editor/inspector/asset_doc_owner.odin). Every view that edits an asset
//   shares its one document.
// An editor with its own working copy of a file, applied at once, would add
// a third.
//
// What uses them:
// - File ▸ Save saves every dirty document.
// - A view names the document it shows (view_document_set). Its tab menu
//   offers Save and Discard for it, and its title carries a star while the
//   document is dirty (view_title).
// - The project window marks dirty files with a star.
// - Quitting with dirty documents asks first (editor/quit_prompt.odin).
//
// Discard is final: the document goes back to its file and its undo steps
// go. Callers confirm first (document_discard.odin).

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "moonhug:libs/log"

Document :: struct {
	owner:       int,    // index of its owner, filled by `documents`
	key:         rawptr, // the owner's handle for it, nil for an owner with one document
	path:        string, // its file, "" for a scene never saved. Borrowed for the frame
	dirty:       bool,
	// Discard can run now. False for a scene with no file or while a
	// simulation runs.
	can_discard: bool,
}

Document_Owner :: struct {
	name:    string,
	// Appends the owner's open documents. `owner` is left for `documents`.
	list:    proc(out: ^[dynamic]Document),
	// Writes the document to its file. False when it could not, the reason logged.
	save:    proc(key: rawptr) -> bool,
	// The document back to its file, its undo steps dropped.
	discard: proc(key: rawptr),
}

// The document a view shows: its owner's name and key. ok=false when the
// view shows none right now.
View_Document_Proc :: proc() -> (owner: string, key: rawptr, ok: bool)

@(private = "file") _owners: [dynamic]Document_Owner
@(private = "file") _view_documents: map[string]View_Document_Proc

// Registers the code that holds loaded copies of some files. Called once per
// owner from a @(provider_install) proc.
document_owner_add :: proc(o: Document_Owner) {
	context.allocator = runtime.default_allocator()
	for e in _owners do if e.name == o.name do panic(fmt.tprintf("document owner %q is added twice", o.name))
	append(&_owners, o)
}

// The document the view with id `view` shows (the text after ### in its
// title). Called once per view from a @(provider_install) proc.
view_document_set :: proc(view: string, p: View_Document_Proc) {
	context.allocator = runtime.default_allocator()
	if view in _view_documents do panic(fmt.tprintf("view %q names its document twice", view))
	_view_documents[strings.clone(view)] = p
}

// Every open document.
documents :: proc(allocator := context.temp_allocator) -> []Document {
	out := make([dynamic]Document, allocator)
	for o, i in _owners {
		start := len(out)
		o.list(&out)
		for j in start ..< len(out) do out[j].owner = i
	}
	return out[:]
}

// The open documents with unsaved edits.
documents_dirty :: proc(allocator := context.temp_allocator) -> []Document {
	out := make([dynamic]Document, allocator)
	for d in documents(context.temp_allocator) do if d.dirty do append(&out, d)
	return out[:]
}

// The open document of owner `owner` with handle `key`, as it is now.
document_find :: proc(owner: string, key: rawptr) -> (Document, bool) {
	for d in documents(context.temp_allocator) {
		if d.key == key && _owners[d.owner].name == owner do return d, true
	}
	return {}, false
}

// The document view `view` shows. ok=false when it shows none.
view_document :: proc(view: string) -> (Document, bool) {
	p, has := _view_documents[view]
	if !has do return {}, false
	owner, key, ok := p()
	if !ok do return {}, false
	return document_find(owner, key)
}

document_owner_name :: proc(d: Document) -> string {
	return _owners[d.owner].name
}

// The file name a person reads: the path's last part, or "Untitled scene".
document_name :: proc(d: Document) -> string {
	if d.path == "" do return "Untitled scene"
	return filepath.base(d.path)
}

// Writes `d` to its file. False when it has no file or the write failed.
document_save :: proc(d: Document) -> bool {
	if d.path == "" {
		log.errorf("[Save] %s has no file yet, save it from the Hierarchy's scene menu", document_name(d))
		return false
	}
	return _owners[d.owner].save(d.key)
}

// Drops `d`'s unsaved edits for good. The caller has confirmed.
document_discard :: proc(d: Document) {
	if !d.can_discard do return
	_owners[d.owner].discard(d.key)
}

// Saves every dirty document. `failed` counts the ones that could not be
// written, an untitled scene among them.
documents_save_all :: proc() -> (saved, failed: int) {
	for d in documents_dirty() {
		if document_save(d) {
			saved += 1
		} else {
			failed += 1
		}
	}
	return
}

// The cleaned paths of the dirty documents, for marking files.
documents_dirty_paths :: proc(allocator := context.temp_allocator) -> map[string]bool {
	out := make(map[string]bool, allocator)
	for d in documents_dirty() {
		if d.path == "" do continue
		clean, _ := filepath.clean(d.path, allocator)
		out[clean] = true
	}
	return out
}

// `title` with a star before its ### while the view's document is dirty.
// imgui keys the window, its dock place and the saved layout on the text
// after ###, so the star never moves the view.
view_title :: proc(title: cstring) -> cstring {
	s := string(title)
	i := strings.last_index(s, "###")
	if i < 0 do return title
	d, ok := view_document(s[i + 3:])
	if !ok || !d.dirty do return title
	return strings.clone_to_cstring(fmt.tprintf("%s *%s", s[:i], s[i:]), context.temp_allocator)
}
