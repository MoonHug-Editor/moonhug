package physics2d

import "moonhug:packages/engine"

// Physics 2D project settings — a tab in the editor's Project Settings window
// (docs/core/Plugins.md "Project settings"). Consumed by polling in physics_step:
// an edit, undo or redo reaches the live world on the next step, and the game
// binary reads the same ProjectSettings/physics_2d.json.

Physics2D_Settings :: struct {
	gravity: [2]f32,
	// The collision layers the 2D colliders use: their names and which
	// pairs collide (layers.odin). Unset is the built-in default: layer 0
	// "Default", every pair colliding.
	layers:  engine.Asset_GUID `ref:"Physics2D_Layers"`,
}

@(project_settings={name="Physics 2D"})
physics2d_settings := Physics2D_Settings{gravity = GRAVITY_DEFAULT}

@(private = "file")
_settings: struct {
	loaded:  bool,
	applied: [2]f32,
}

// Loads the file into the var, once per run: the physics step and the layer
// names both need it, and the names are read in the editor without a step.
_settings_ensure_loaded :: proc() {
	if _settings.loaded do return
	_settings.loaded = true
	engine.project_settings_load("Physics 2D", &physics2d_settings)
	_settings.applied = physics2d_settings.gravity
	if _state.gravity == {} && physics2d_settings.gravity != {} {
		_state.gravity = physics2d_settings.gravity
	}
}

// Loads the file once, then tracks the var. Only the var's OWN changes push —
// explicit set_gravity calls stand until the setting changes again.
_settings_sync :: proc() {
	if !_settings.loaded {
		_settings_ensure_loaded()
		return
	}
	if physics2d_settings.gravity != _settings.applied {
		_settings.applied = physics2d_settings.gravity
		set_gravity(physics2d_settings.gravity)
	}
}
