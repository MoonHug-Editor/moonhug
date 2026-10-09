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

// --- Player -----------------------------------------------------------------

// The standalone player's window and boot scene (plugins/engine/standalone.odin).
Player_Settings :: struct {
    title:      string,
    width:      i32 `decor:min(1)`,
    height:     i32 `decor:min(1)`,
    boot_scene: string `decor:help(text="The scene guid the player boots when no program argument and no exported boot scene names one. Empty leaves the player on an error.")`,
}

@(project_settings={name="Player"})
player_settings := Player_Settings{title = "App", width = 800, height = 600}

@(private = "file")
_player_settings_loaded: bool

_ensure_player_settings :: proc() {
    if _player_settings_loaded do return
    _player_settings_loaded = true
    project_settings_load("Player", &player_settings)
}
