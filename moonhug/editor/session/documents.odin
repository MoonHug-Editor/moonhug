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
// - A view names the asset it edits (@(view_document)). Its tab menu offers
//   Save and Discard for that asset's document, and its title carries a star
//   while the document is dirty (view_title).
// - The project window marks dirty files with a star.
// - Quitting with dirty documents asks first (editor/quit_prompt.odin).
//
// Discard is final: the document goes back to its file and its undo steps
// go. Callers confirm first (document_discard.odin).

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import core "moonhug:libs/core"
import "moonhug:libs/log"

Document :: struct {
	owner:       int,    // index of its owner, filled by `documents`
	key:         rawptr, // the owner's handle for it, nil for an owner with one document
	guid:        core.Asset_GUID, // the asset it is, {} for a scene never saved
	path:        string, // its file, "" for a scene never saved. Borrowed for the frame
	dirty:       bool,
	// Discard can run now. False for a scene with no file or while a
	// simulation runs.
	can_discard: bool,
	// The view that holds it, an editor's working copy, which closing that
	// view would lose. "" for a document any view may show.
	view:        string,
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

// A view as the attribute procs that extend it see it (docs/core/Views.md):
// @(view_document), @(view_menu) actions and their predicates, @(view_tab_bar)
// widgets. Several instances of one window are several views of one id.
View :: struct {
	key: string, // the text after ### in its title: "Inspector", or "shader_graph/<guid>" for a window instance
	id:  string, // the view's id, the key up to its first `/`
}

// The view `key` names.
view_of :: proc(key: string) -> View {
	id := key
	if slash := strings.index_byte(key, '/'); slash >= 0 do id = key[:slash]
	return {key = key, id = id}
}

// The asset the view edits right now, {} when it edits none.
View_Document_Proc :: proc(view: View) -> core.Asset_GUID

@(private = "file") _owners: [dynamic]Document_Owner
@(private = "file") _view_documents: map[string]View_Document_Proc
@(private = "file") _view_assets: map[string]core.Asset_GUID // window instance key -> the asset it is open for

// Registers the code that holds loaded copies of some files. Called once per
// owner from a @(provider_install) proc.
document_owner_add :: proc(o: Document_Owner) {
	context.allocator = runtime.default_allocator()
	for e in _owners do if e.name == o.name do panic(fmt.tprintf("document owner %q is added twice", o.name))
	append(&_owners, o)
}

// Names the asset the view with id `view` edits (the text after ### in its
// title). The generated registrations call it, one per @(view_document) proc
// (prebuild/view_chrome_gen): the editor's _register_view_chrome and the
// tests' register_view_documents.
@(extension_point={attribute="view_document", target="proc", fields="view"})
view_document_add :: proc(view: string, p: View_Document_Proc) {
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

// A window instance opened for an asset (editor/window) edits that asset.
// The window registry sets it when the instance opens and clears it when it
// closes. `key` is the instance's id, the text after ### in its title.
view_asset_set :: proc(key: string, asset: core.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	if key not_in _view_assets do _view_assets[strings.clone(key)] = asset
}

view_asset_clear :: proc(key: string) {
	context.allocator = runtime.default_allocator()
	if key not_in _view_assets do return
	k, _ := delete_key(&_view_assets, key)
	delete(k)
}

// The document the view `key` edits, the text after ### in its title. A
// window instance opened for an asset edits that asset. Otherwise the
// view's @(view_document) proc names it, the view being the key up to its
// first `/`. ok=false when it edits none.
view_document :: proc(key: string) -> (Document, bool) {
	// A working copy the view holds names itself.
	for d in documents(context.temp_allocator) do if d.view == key do return d, true
	guid, opened_for := _view_assets[key]
	if !opened_for {
		view := view_of(key)
		p, has := _view_documents[view.id]
		if !has do return {}, false
		guid = p(view)
	}
	if guid == {} do return {}, false
	for d in documents(context.temp_allocator) do if d.guid == guid do return d, true
	return {}, false
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
