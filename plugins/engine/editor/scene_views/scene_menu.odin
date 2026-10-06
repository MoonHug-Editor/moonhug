package scene_views

// The scene file menu items: File/Save Scene saves the active scene, and
// Assets/Create/Scene writes a new scene into the folder the project view shows.

import "core:path/filepath"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"

// Saves the active scene to its file (the hierarchy header menu's Save).
@(menu_item={path="File/Save Scene", order=1, shortcut=""})
scene_save_menu :: proc() {
	scene := engine.sm_scene_get_active()
	if scene == nil || len(scene.path) == 0 do return
	engine.scene_save(scene, scene.path)
}

@(menu_item={path="Assets/Create/Scene", order=0, shortcut=""})
scene_create_menu :: proc() {
	scene := engine.scene_new()
	save_path, _ := filepath.join({viewport.project_dir(), "Scene.scene"}, context.temp_allocator)
	engine.scene_save(scene, save_path)
}
