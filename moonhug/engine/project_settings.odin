package engine

// Project settings persistence (docs/Plugins.md "Project settings").
//
// A project setting is a package-level struct var marked
// @(project_settings={name="Tab Name"}). The editor's Project Settings window
// lists every marked var as a tab (project_settings_gen), draws it through the
// inspector, and persists it to ProjectSettings/<slug>.json on change. The
// OWNING system loads its own file (these helpers) and consumes the var by
// polling, so an edit — typed, undone or redone — reaches the runtime without
// editor coupling, and the game binary reads the same files.

import "core:encoding/json"
import "core:os"
import "core:strings"

ENGINE_PROJECT_SETTINGS_DIR :: "ProjectSettings"

// "Physics 2D" -> "ProjectSettings/physics_2d.json". Temp-allocated.
project_settings_file :: proc(name: string) -> string {
    slug, _ := strings.replace_all(strings.to_lower(name, context.temp_allocator), " ", "_", context.temp_allocator)
    return strings.concatenate({ENGINE_PROJECT_SETTINGS_DIR, "/", slug, ".json"}, context.temp_allocator)
}

// Reads the tab's file into the settings struct. A missing or unreadable file
// leaves the struct as-is (its var initializer is the default), so this is
// safe to call unconditionally and more than once. Typed because unmarshal
// needs the pointer type — callers (owners and generated registration) always
// have it.
project_settings_load :: proc(name: string, v: ^$T) -> bool {
    if v == nil do return false
    data, read_err := os.read_entire_file(project_settings_file(name), context.temp_allocator)
    if read_err != nil do return false
    return json.unmarshal(data, v) == nil
}

project_settings_save :: proc(name: string, ptr: rawptr, tid: typeid) -> bool {
    if ptr == nil || tid == nil do return false
    os.make_directory(ENGINE_PROJECT_SETTINGS_DIR)
    opts := json.Marshal_Options{
        spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
        sort_maps_by_key = true,
    }
    marshaled, merr := json.marshal(any{ptr, tid}, opts, context.temp_allocator)
    if merr != nil do return false
    data := json_canonicalize_floats(marshaled, context.temp_allocator)
    return os.write_entire_file(project_settings_file(name), data) == nil
}

// --- Time -------------------------------------------------------------------

Time_Settings :: struct {
    fixed_rate: f32 `decor:min(1)`, // fixed simulation ticks per second (docs/FixedTick.md)
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
