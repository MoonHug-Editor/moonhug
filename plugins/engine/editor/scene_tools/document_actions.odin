package scene_tools

// The engine's side of viewport.Document_Actions: the open documents are the
// scene manager's loaded scenes. Installed from @(init), so the editor and the
// test binary both have it.

import "base:runtime"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"

install_document_actions :: proc() {
	viewport.set_document_actions({
		save_all        = _doc_save_all,
		open_paths      = _doc_open_paths,
		snapshot_active = _doc_snapshot_active,
		active_path     = _doc_active_path,
	})
}

@(init, private = "file")
_install_document_actions :: proc "contextless" () {
	context = runtime.default_context()
	install_document_actions()
}

@(private = "file")
_doc_save_all :: proc() -> int {
	sm := engine.ctx_scene_manager()
	if sm == nil do return 0
	saved := 0
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !scene.dirty || len(scene.path) == 0 do continue
		engine.scene_save(scene, scene.path)
		saved += 1
	}
	return saved
}

@(private = "file")
_doc_open_paths :: proc() -> []string {
	sm := engine.ctx_scene_manager()
	if sm == nil do return {}
	out := make([dynamic]string, 0, sm.count, context.temp_allocator)
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) || len(scene.path) == 0 do continue
		append(&out, scene.path)
	}
	return out[:]
}

@(private = "file")
_doc_snapshot_active :: proc() -> (path: string, data: []byte, ok: bool) {
	scene := engine.sm_scene_get_active()
	if scene == nil do return "", nil, false
	snapshot, sok := engine.scene_serialize(scene)
	return scene.path, snapshot if sok else nil, true
}

@(private = "file")
_doc_active_path :: proc() -> (path: string, ok: bool) {
	scene := engine.sm_scene_get_active()
	if scene == nil do return "", false
	return scene.path, true
}
