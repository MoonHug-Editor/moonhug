package importers

// The engine's asset actions for the project view: opening a scene, opening
// it additively, and writing a scene variant. Installed through
// @(provider_install).

import "core:path/filepath"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"

@(provider_install)
install_asset_actions :: proc() {
	asset_pipeline.set_asset_actions({
		open           = _open,
		open_additive  = _open_additive,
		create_variant = engine.scene_create_variant_file,
	})
}

@(private = "file")
_open :: proc(path: string) -> bool {
	if filepath.ext(path) != ".scene" do return false
	scene := engine.scene_load_single_path(path)
	engine.sm_scene_set_active(scene)
	return scene != nil
}

@(private = "file")
_open_additive :: proc(path: string) -> bool {
	if filepath.ext(path) != ".scene" do return false
	return engine.scene_load_additive_path(path) != nil
}
