package scene_views

// Loaded scenes as open documents (moonhug:editor/session, documents.odin).
// The Hierarchy and the Scene view show the active scene, so their tab menus
// save and discard it and their titles carry its star.

import "moonhug:editor/session"
import engine "moonhug:packages/engine"

SCENE_DOCUMENTS :: "scenes"

@(provider_install)
_install_scene_documents :: proc() {
	session.document_owner_add({name = SCENE_DOCUMENTS, list = _scene_documents_list, save = _scene_document_save, discard = _scene_document_discard})
	session.view_document_set("Hierarchy", _active_scene_document)
	session.view_document_set("Scene", _active_scene_document)
}

// Every loaded scene. Discard needs a file to read back and no simulation
// running, which holds the scene it restores on Stop.
@(private = "file")
_scene_documents_list :: proc(out: ^[dynamic]session.Document) {
	// No user context, no world: nothing is loaded.
	if engine.ctx_get() == nil do return
	sm := engine.ctx_scene_manager()
	playing := engine.application_is_playing()
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) do continue
		append(out, session.Document{key = scene, path = scene.path, dirty = scene.dirty, can_discard = len(scene.path) > 0 && !playing})
	}
}

@(private = "file")
_scene_document_save :: proc(key: rawptr) -> bool {
	scene := (^engine.Scene)(key)
	return engine.scene_save(scene, scene.path)
}

@(private = "file")
_scene_document_discard :: proc(key: rawptr) {
	_hierarchy_discard_scene((^engine.Scene)(key))
}

@(private = "file")
_active_scene_document :: proc() -> (owner: string, key: rawptr, ok: bool) {
	if engine.ctx_get() == nil do return "", nil, false
	scene := engine.sm_scene_get_active()
	if scene == nil do return "", nil, false
	return SCENE_DOCUMENTS, scene, true
}
