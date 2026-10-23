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
	// The material of every collider that names none (physics_material.odin).
	// Unset is a new Physics Material's defaults: friction 0.6, bounciness 0,
	// both combines Average.
	default_material: engine.Asset_GUID `ref:"PhysicsMaterial" expand`,
	// How many convex decompositions the editor computes at once
	// (editor/hull_jobs.odin). The game never reads it.
	decompositions_at_once: int `decor:range(1, 4) decor:help(text="How many convex decompositions the editor computes at the same time, each in its own process. Each one already uses several cores, and a dense model that is not a closed mesh takes about 2 GB of memory while it runs, so more than 2 or 3 at once mostly slows them all down and can run the machine out of memory.")`,
}

@(project_settings={name="Physics 3D"})
physics3d_settings := Physics3D_Settings{decompositions_at_once = 2}

// The settings' decompositions_at_once, 1 to 4 whatever the file says.
decompositions_at_once :: proc() -> int {
	_settings_ensure_loaded()
	return clamp(physics3d_settings.decompositions_at_once, 1, 4)
}

@(private = "file")
_settings_loaded: bool

// Loads the file into the var, once per run.
_settings_ensure_loaded :: proc() {
	if _settings_loaded do return
	_settings_loaded = true
	engine.project_settings_load("Physics 3D", &physics3d_settings)
}
