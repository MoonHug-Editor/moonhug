package inspector

// Asset documents as open documents (session/documents.odin): every
// serialized asset opened for editing, in the Project Inspector or in a
// foldout under a component. Import settings are not among them: they commit
// through Apply and go back through Revert. A Project Inspector instance's
// document is the asset it shows (project_inspector_window.odin).
//
// An editor's working copy is one too (asset_doc_copies.odin), of the view
// that holds it: saving it applies it, discarding it drops its edits.

import "moonhug:editor/session"

ASSET_DOCUMENTS :: "asset_documents"
ASSET_DOC_COPIES :: "asset_doc_copies"

@(provider_install)
_install_asset_documents :: proc() {
	session.document_owner_add({name = ASSET_DOCUMENTS, list = _asset_documents_list, save = _asset_document_save, discard = _asset_document_discard})
	session.document_owner_add({name = ASSET_DOC_COPIES, list = _doc_copies_list, save = _doc_copy_save, discard = _doc_copy_discard})
}

@(private = "file")
_doc_copies_list :: proc(out: ^[dynamic]session.Document) {
	for c in _doc_copies() {
		append(out, session.Document{key = c, guid = c.guid, path = c.path, dirty = c.dirty, can_discard = true, view = c.view})
	}
}

@(private = "file")
_doc_copy_save :: proc(key: rawptr) -> bool {
	return asset_doc_copy_apply((^Asset_Doc_Copy)(key).id)
}

@(private = "file")
_doc_copy_discard :: proc(key: rawptr) {
	asset_doc_copy_discard((^Asset_Doc_Copy)(key).id)
}

@(private = "file")
_asset_documents_list :: proc(out: ^[dynamic]session.Document) {
	for _, doc in _docs {
		if doc.kind != .File do continue
		append(out, session.Document{key = doc, guid = doc.guid, path = doc.path, dirty = doc.dirty, can_discard = true})
	}
}

@(private = "file")
_asset_document_save :: proc(key: rawptr) -> bool {
	return asset_doc_save((^Asset_Doc)(key))
}

@(private = "file")
_asset_document_discard :: proc(key: rawptr) {
	asset_doc_discard((^Asset_Doc)(key))
}

