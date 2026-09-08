package physics2d

import "moonhug:engine"

// Physics 2D project settings — a tab in the editor's Project Settings window
// (docs/Plugins.md "Project settings"). Consumed by polling in physics_step:
// an edit, undo or redo reaches the live world on the next step, and the game
// binary reads the same ProjectSettings/physics_2d.json.

Physics2D_Settings :: struct {
	gravity: [2]f32,
}

@(project_settings={name="Physics 2D"})
physics2d_settings := Physics2D_Settings{gravity = GRAVITY_DEFAULT}

@(private = "file")
_settings: struct {
	loaded:  bool,
	applied: [2]f32,
}

// Loads the file once, then tracks the var. Only the var's OWN changes push —
// explicit set_gravity calls stand until the setting changes again.
_settings_sync :: proc() {
	if !_settings.loaded {
		_settings.loaded = true
		engine.project_settings_load("Physics 2D", &physics2d_settings)
		_settings.applied = physics2d_settings.gravity
		if _state.gravity == {} && physics2d_settings.gravity != {} {
			_state.gravity = physics2d_settings.gravity
		}
		return
	}
	if physics2d_settings.gravity != _settings.applied {
		_settings.applied = physics2d_settings.gravity
		set_gravity(physics2d_settings.gravity)
	}
}
