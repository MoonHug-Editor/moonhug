package scene_views

// Loaded scenes as open documents (moonhug:editor/session, documents.odin).
// The Hierarchy and the Scene view edit the active scene, so their tab menus
// save and discard it and their titles carry its star.

import "moonhug:editor/session"
import engine "moonhug:packages/engine"

SCENE_DOCUMENTS :: "scenes"

@(provider_install)
_install_scene_documents :: proc() {
	session.document_owner_add({name = SCENE_DOCUMENTS, list = _scene_documents_list, save = _scene_document_save, discard = _scene_document_discard})
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
		append(out, session.Document{key = scene, guid = scene.asset_guid, path = scene.path, dirty = scene.dirty, can_discard = len(scene.path) > 0 && !playing})
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

@(view_document={view="Hierarchy"})
hierarchy_document :: proc() -> engine.Asset_GUID {
	return _active_scene_guid()
}

@(view_document={view="Scene"})
scene_view_document :: proc() -> engine.Asset_GUID {
	return _active_scene_guid()
}

@(private = "file")
_active_scene_guid :: proc() -> engine.Asset_GUID {
	if engine.ctx_get() == nil do return {}
	scene := engine.sm_scene_get_active()
	if scene == nil do return {}
	return scene.asset_guid
}
