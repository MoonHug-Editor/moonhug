package tests

import "../engine"

import "core:os"
import "core:strings"
import "core:testing"

// Save/load round-trip through the ProjectSettings/<slug>.json files the
// Project Settings window and the runtime owners share. The file is removed
// after — ProjectSettings/ holds committed files.
@(test)
test_project_settings_round_trip :: proc(t: ^testing.T) {
	Probe :: struct {
		rate:    f32,
		gravity: [2]f32,
		label:   string,
	}

	name :: "Test Probe Settings"
	path := engine.project_settings_file(name)
	testing.expect(t, strings.has_suffix(path, "/test_probe_settings.json"),
		"tab name should slug into a lower snake file name")
	// Tests run from the repo root, where no ProjectSettings dir exists (the
	// binaries chdir into moonhug/) — remove the file AND the created dir.
	defer {
		os.remove(path)
		os.remove(engine.PROJECT_SETTINGS_DIR) // os.remove also removes an empty dir
	}

	saved := Probe{rate = 120, gravity = {0, -3.5}, label = "probe"}
	testing.expect(t, engine.project_settings_save(name, &saved, typeid_of(Probe)))

	loaded := Probe{}
	testing.expect(t, engine.project_settings_load(name, &loaded))
	testing.expect_value(t, loaded.rate, f32(120))
	testing.expect_value(t, loaded.gravity, [2]f32{0, -3.5})
	testing.expect(t, loaded.label == "probe")
	delete(loaded.label)

	// A missing file leaves the struct untouched — defaults come from the var
	// initializer, not the loader.
	untouched := Probe{rate = 60}
	testing.expect(t, !engine.project_settings_load("No Such Tab", &untouched))
	testing.expect_value(t, untouched.rate, f32(60))
}

// The Time setting reaches the tick rate by polling: fixed_rate() prefers an
// explicit fixed_set_rate override, then the settings var, then the default.
@(test)
test_time_settings_polling :: proc(t: ^testing.T) {
	prev := engine.time_settings
	defer {
		engine.time_settings = prev
		engine.fixed_set_rate(0)
	}

	engine.time_settings.fixed_rate = 30
	engine.fixed_set_rate(0)
	testing.expect_value(t, engine.fixed_rate(), f32(30))

	// Explicit override wins.
	engine.fixed_set_rate(90)
	testing.expect_value(t, engine.fixed_rate(), f32(90))

	// Zeroed setting falls back to the default.
	engine.fixed_set_rate(0)
	engine.time_settings.fixed_rate = 0
	testing.expect_value(t, engine.fixed_rate(), engine.FIXED_RATE_DEFAULT)
}
