package inspector

// Documents of authored sub-assets: a sub-asset whose file holds its data
// and whose provider reads and writes it (subassets.Provider text, load and
// store), such as a material kept in a scene file. One is the same document
// a file has (Asset_Doc), named by PPtr{the file's guid, the local id}, and
// is edited by the same rows and the same undo. What differs is where its
// data goes:
//
//   - It is read from its file's provider. While that file is open in the
//     editor, every change is stored into it at once: the file holds the
//     unsaved edit and shows as edited, and nothing is written to disk here.
//   - While that file is not open, the document holds the edit like a file's
//     document, and a save writes it into the file.
//   - When the data changes under it (its file was reverted or reloaded),
//     the document is read again.

import "base:runtime"
import "core:fmt"
import strings "core:strings"
import "moonhug:editor/subassets"
import "moonhug:editor/undo"
import core "moonhug:libs/core"
import "moonhug:libs/log"

// The file the reference field drawn now belongs to: the scene of the
// object being inspected, or the file of the sub-asset whose document is
// drawn. A picker lists that file's own sub-assets first, and makes a new
// sub-asset in it (the "(sub-asset)" rows). Not set for a file asset's
// field. The scene inspector sets it around an object's components,
// draw_asset_doc around a document.
Sub_Asset_Scope :: struct {
	set:   bool,
	owner: core.Asset_GUID, // empty for a file never saved
}

sub_asset_scope: Sub_Asset_Scope

// Whether the field drawn now can hold the sub-asset `ref`: any sub-asset a
// file's provider lists. One of a file never saved has no guid another file
// could name it by, so only that file's own fields hold it.
sub_asset_in_scope :: proc(ref: core.PPtr) -> bool {
	if _, ok := subassets.get(ref); !ok do return false
	if !core.asset_guid_is_empty(ref.guid) do return true
	return sub_asset_scope.set && core.asset_guid_is_empty(sub_asset_scope.owner)
}

// Set while a document is replaced by its sub-asset's new data: that change
// came from the file and is not stored back.
@(private = "file")
_from_file: bool

// The document of the sub-asset `ref`, read through its file's provider on
// first use and again when its data changed. nil when the file's sub-assets
// are not documents, `ref` names none, or the data does not load as an
// asset (it has no `__type_guid`).
@(private)
_sub_asset_doc_get :: proc(ref: core.PPtr) -> ^Asset_Doc {
	context.allocator = doc_alloc()
	p, path, has := subassets.of(ref.guid)
	if !has || p.text == nil || p.load == nil do return nil
	text, ok := p.text(ref)
	if !ok do return nil
	key := Doc_Key{ref, .File}
	if doc, found := _docs[key]; found {
		if doc.path != path {
			delete(doc.path)
			doc.path = strings.clone(path)
		}
		// It holds an edit its file does not: kept, and moved into the file
		// when that was opened since.
		if doc.dirty {
			if subassets.editable(ref.guid) do _sub_asset_doc_store(doc)
			return doc
		}
		if string(doc.applied) != text {
			fresh, loaded := p.load(ref, text)
			if !loaded do return doc
			_applied_set(doc, text)
			_from_file = true
			_doc_replace(doc, fresh, dirty = false)
			_from_file = false
		}
		return doc
	}
	data, loaded := p.load(ref, text)
	if !loaded do return nil
	doc := new(Asset_Doc)
	doc.ref = ref
	doc.path = strings.clone(path)
	doc.data = data
	_applied_set(doc, text)
	if _docs == nil do _docs = make(map[Doc_Key]^Asset_Doc)
	_docs[key] = doc
	return doc
}

// Takes a change of the sub-asset's document (asset_doc_changed).
//   - Its file is open in the editor: the change is stored into that file at
//     once. The file holds the unsaved edit, and the document is not dirty.
//   - Its file is not open: the document holds the edit, dirty like a file's
//     document, until asset_doc_save writes it into the file.
@(private)
_sub_asset_doc_store :: proc(doc: ^Asset_Doc) -> bool {
	if _from_file do return true
	p, _, has := subassets.of(doc.ref.guid)
	if !has do return false
	if p.store != nil && subassets.editable(doc.ref.guid) {
		doc.dirty = false
		if !p.store(doc.ref, doc.data) {
			log.warningf("%s: the change to sub-asset %d is not kept", doc.path, i64(doc.ref.local_id))
			return false
		}
		// The stored text: what a later read compares with.
		if stored, read := p.text(doc.ref); read do _applied_set(doc, stored)
		if doc.ref.guid == core.EMBEDDED_ASSETS do _embedded_holder_changed(doc.ref)
		return true
	}
	if p.save == nil {
		doc.dirty = false
		log.warningf("%s: the file of sub-asset %d is not open, the change is not kept", doc.path, i64(doc.ref.local_id))
		return false
	}
	doc.dirty = true
	return true
}

// Writes a dirty sub-asset document into its file (asset_doc_save). One
// whose file was opened since goes into the open file.
@(private)
_sub_asset_doc_save :: proc(doc: ^Asset_Doc) -> bool {
	if !doc.dirty do return true
	p, _, has := subassets.of(doc.ref.guid)
	if !has do return false
	if p.store != nil && subassets.editable(doc.ref.guid) do return _sub_asset_doc_store(doc)
	if p.save == nil || !p.save(doc.ref, doc.data) {
		log.error(fmt.tprintf("asset_docs: sub-asset %d of %s is not saved", i64(doc.ref.local_id), doc.path))
		return false
	}
	doc.dirty = false
	if stored, read := p.text(doc.ref); read do _applied_set(doc, stored)
	return true
}

// A dirty sub-asset document whose file is open now moves its edit into
// that file: the file was opened after the edit. From then on the file holds
// it, whichever of the two is saved first.
@(private)
_sub_asset_docs_settle :: proc() {
	for _, doc in _docs {
		if doc.ref.local_id == 0 || !doc.dirty do continue
		p, _, has := subassets.of(doc.ref.guid)
		if has && p.store != nil && subassets.editable(doc.ref.guid) do _sub_asset_doc_store(doc)
	}
}

// Discard of a dirty sub-asset document: back to what its file holds.
@(private)
_sub_asset_doc_discard :: proc(doc: ^Asset_Doc) {
	p, _, has := subassets.of(doc.ref.guid)
	if !has || p.text == nil || p.load == nil do return
	text, ok := p.text(doc.ref)
	if !ok do return
	fresh: any
	loaded: bool
	{
		context.allocator = doc_alloc()
		fresh, loaded = p.load(doc.ref, text)
	}
	if !loaded do return
	// On the caller's allocator, like every purge.
	undo.purge_asset(undo.get(), doc.ref.guid)
	_applied_set(doc, text)
	_from_file = true
	_doc_replace(doc, fresh, dirty = false)
	_from_file = false
}

// --- What holds an embedded asset ----------------------------------------------
//
// An embedded asset is part of the field that holds it, so its edit is an
// edit of what holds that field: the scene of the object, the asset document,
// or a settings struct. The holder is the inspector's owner where the
// embedded asset is edited from: its foldout under the field, and the picker
// row that made it.

@(private = "file")
_Embedded_Holder :: struct {
	kind:      undo.Owner_Kind,
	scene:     undo.Scene_Ref, // .Pooled
	asset:     core.PPtr,      // .Asset
	asset_doc: undo.Doc_Kind,  // .Asset
}

// By the embedded asset's id. Default allocator: lives for the session, as the
// embedded assets do.
@(private = "file")
_embedded_holders: map[core.Local_ID]_Embedded_Holder

// The inspector's current owner holds the field with the embedded asset `ref`.
embedded_holder_set :: proc(ref: core.PPtr) {
	if ref.guid != core.EMBEDDED_ASSETS do return
	o, ok := undo.current_owner()
	if !ok do return
	if _embedded_holders == nil do _embedded_holders = make(map[core.Local_ID]_Embedded_Holder, runtime.default_allocator())
	_embedded_holders[ref.local_id] = {kind = o.kind, scene = o.scene, asset = o.asset, asset_doc = o.asset_doc}
}

// The embedded asset `ref` changed: its holder is edited.
//   - A scene object's field: the scene is marked edited, and its save
//     writes the new data inside the field.
//   - An asset document's field: the document takes the change as its own
//     edit. A sub-asset's document stores it into its file, which goes on to
//     its own holder when it is embedded too.
//   - A settings struct: nothing. Its window saves it when its text changes.
@(private = "file")
_embedded_holder_changed :: proc(ref: core.PPtr) {
	h, known := _embedded_holders[ref.local_id]
	if !known {
		log.errorf("embedded asset %d changed with no known holder: nothing is marked edited", i64(ref.local_id))
		return
	}
	switch h.kind {
	case .Pooled:
		undo.scene_mark_dirty(h.scene)
	case .Asset:
		holder, found := _docs[Doc_Key{h.asset, .File}]
		if !found || h.asset_doc != .File do return
		asset_doc_mark_edited(holder)
		asset_doc_changed(holder)
	case .Raw, .None:
	}
}

@(private = "file")
_applied_set :: proc(doc: ^Asset_Doc, text: string) {
	context.allocator = doc_alloc()
	delete(doc.applied)
	doc.applied = transmute([]byte)strings.clone(text)
}
