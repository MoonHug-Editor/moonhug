package inspector

// Asset documents as open documents (session/documents.odin): every
// serialized asset opened for editing, in the Project Inspector or in a
// foldout under a component. Import settings are not among them: they commit
// through Apply and go back through Revert. The Project Inspector's document
// is the asset it shows.

import core "moonhug:libs/core"
import "moonhug:editor/session"

ASSET_DOCUMENTS :: "asset_documents"

@(provider_install)
_install_asset_documents :: proc() {
	session.document_owner_add({name = ASSET_DOCUMENTS, list = _asset_documents_list, save = _asset_document_save, discard = _asset_document_discard})
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

// The asset the Project Inspector shows, locked or not.
@(view_document={view="Project Inspector"})
project_inspector_document :: proc(view: session.View) -> core.Asset_GUID {
	doc := inspectorData.doc
	if inspectorData.mode != .Asset || doc == nil || doc.kind != .File do return {}
	return doc.guid
}
