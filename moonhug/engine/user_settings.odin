package engine

// Per-developer settings persistence, the UserSettings half of
// project_settings.odin.
//
// A user setting is a package-level var marked @(user_settings={name="..."}):
//
//   @(user_settings={name="Animation"})
//   anim_view_prefs := Anim_View_Prefs{ends_on_last_frame = false}
//
// The generator loads every marked var at editor start and saves them at
// shutdown, so a plugin keeps a preference without the editor's own settings
// struct having a field for it.
//
// WHICH ONE TO USE:
//
// - @(project_settings) is about the PROJECT. Committed, shared by everyone on
//   the checkout, and the game binary reads the same file. Physics gravity.
// - @(user_settings) is about the PERSON. Never committed, editor only. Where
//   your playhead stops, which panel you left open.
//
// Putting a personal preference in ProjectSettings commits it and hands it to
// the game, which is the wrong file and the wrong reader.
//
// The editor's own window geometry and panel flags stay in EditorSettings
// (editor/window.odin): one struct, one file, hand-copied fields. That is
// older than this and not worth churning — but nothing new needs to go there.

import "core:encoding/json"
import "core:os"
import "core:strings"

// Never committed: .gitignore covers the directory, the same as Unity's
// UserSettings. Editor/window.odin writes its own file in here too.
USER_SETTINGS_DIR :: "UserSettings"

// "Animation" -> "UserSettings/animation.json". Temp-allocated.
user_settings_file :: proc(name: string) -> string {
    slug, _ := strings.replace_all(strings.to_lower(name, context.temp_allocator), " ", "_", context.temp_allocator)
    return strings.concatenate({USER_SETTINGS_DIR, "/", slug, ".json"}, context.temp_allocator)
}

// Reads the file into the settings struct. A missing or unreadable file leaves
// the struct as-is — its var initializer is the default — so a fresh checkout,
// a deleted UserSettings/ and a first run all behave the same.
user_settings_load :: proc(name: string, v: ^$T) -> bool {
    if v == nil do return false
    data, read_err := os.read_entire_file(user_settings_file(name), context.temp_allocator)
    if read_err != nil do return false
    return json.unmarshal(data, v) == nil
}

user_settings_save :: proc(name: string, ptr: rawptr, tid: typeid) -> bool {
    if ptr == nil || tid == nil do return false
    os.make_directory(USER_SETTINGS_DIR)
    opts := json.Marshal_Options{
        spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
        sort_maps_by_key = true,
    }
    marshaled, merr := json.marshal(any{ptr, tid}, opts, context.temp_allocator)
    if merr != nil do return false
    // Same canonical float text every other serialize path writes, so a saved
    // preference does not churn the file with 0.30000001 style noise.
    data := json_canonicalize_floats(marshaled, context.temp_allocator)
    return os.write_entire_file(user_settings_file(name), data) == nil
}
