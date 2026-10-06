package engine

// The engine's own project settings. The mechanism is core/project_settings.odin.

// --- Time -------------------------------------------------------------------

Time_Settings :: struct {
    fixed_rate: f32 `decor:min(1)`, // fixed simulation ticks per second (plugins/engine/docs/FixedTick.md)
}

@(project_settings={name="Time"})
time_settings := Time_Settings{fixed_rate = FIXED_RATE_DEFAULT}

@(private = "file")
_time_settings_loaded: bool

// Lazy so every binary that ticks (game, editor, tests) picks the file up on
// first use with no init wiring.
_ensure_time_settings :: proc() {
    if _time_settings_loaded do return
    _time_settings_loaded = true
    project_settings_load("Time", &time_settings)
}
