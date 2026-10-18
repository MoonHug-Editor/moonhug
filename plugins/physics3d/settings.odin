package physics3d

import "moonhug:packages/engine"

// Physics 3D project settings — a tab in the editor's Project Settings window
// (docs/core/Plugins.md "Project settings"), saved to
// ProjectSettings/physics_3d.json, which the game binary reads too.

Physics3D_Settings :: struct {
	// The collision layers the 3D colliders use: their names and which
	// pairs collide (layers.odin). Unset is the built-in default: layer 0
	// "Default", every pair colliding.
	layers: engine.Asset_GUID `ref:"Physics3D_Layers"`,
}

@(project_settings={name="Physics 3D"})
physics3d_settings: Physics3D_Settings

@(private = "file")
_settings_loaded: bool

// Loads the file into the var, once per run.
_settings_ensure_loaded :: proc() {
	if _settings_loaded do return
	_settings_loaded = true
	engine.project_settings_load("Physics 3D", &physics3d_settings)
}
