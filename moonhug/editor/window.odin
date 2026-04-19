package editor

import rl "vendor:raylib"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "menu"
import "../engine"

WINDOW_TITLE :: "MoonHug Editor"
VERSION :: #load("../version", string)
PROJECT_SETTINGS_DIR :: "ProjectSettings"
EDITOR_SETTINGS_FILE :: "ProjectSettings/editor_settings.json"

EditorSettings :: struct {
    width:                    i32,
    height:                   i32,
    x:                        i32,
    y:                        i32,
    theme:                    menu.Theme,
    open_scene_guids:         [dynamic]string,
    show_inspector:           bool,
    show_project_inspector:   bool,
    show_project:             bool,
    show_console:             bool,
    show_scene:               bool,
    show_game:                bool,
    show_output:              bool,
    show_hierarchy:           bool,
    show_history:             bool,
    has_view_state:           bool,
}

editor_settings: EditorSettings

load_editor_settings :: proc() -> (w, h, x, y: i32) {
    data, read_err := os.read_entire_file(EDITOR_SETTINGS_FILE, context.temp_allocator)
    if read_err == nil {
        err := json.unmarshal(data, &editor_settings)
        if err == nil {
            if editor_settings.has_view_state {
                menu.show_inspector         = editor_settings.show_inspector
                menu.show_project_inspector = editor_settings.show_project_inspector
                menu.show_project           = editor_settings.show_project
                menu.show_console           = editor_settings.show_console
                menu.show_scene             = editor_settings.show_scene
                menu.show_game              = editor_settings.show_game
                menu.show_output            = editor_settings.show_output
                menu.show_hierarchy         = editor_settings.show_hierarchy
                menu.show_history           = editor_settings.show_history
            }
            if editor_settings.width > 0 && editor_settings.height > 0 {
                return editor_settings.width, editor_settings.height, editor_settings.x, editor_settings.y
            }
        }
    }
    return 0, 0, -1, -1
}

apply_editor_theme :: proc() {
    menu.active_theme = editor_settings.theme
    menu.apply_theme()
}

apply_default_window_size :: proc() {
    monitor := rl.GetCurrentMonitor()
    mw := rl.GetMonitorWidth(monitor)
    mh := rl.GetMonitorHeight(monitor)
    w := i32(f32(mw) * 0.85)
    h := i32(f32(mh) * 0.85)
    rl.SetWindowSize(w, h)
    rl.SetWindowPosition((mw - w) / 2, (mh - h) / 2)
}

save_editor_settings :: proc() {
    os.make_directory(PROJECT_SETTINGS_DIR)
    pos := rl.GetWindowPosition()
    editor_settings.width  = i32(rl.GetScreenWidth())
    editor_settings.height = i32(rl.GetScreenHeight())
    editor_settings.x      = i32(pos.x)
    editor_settings.y      = i32(pos.y)
    editor_settings.theme  = menu.active_theme

    editor_settings.show_inspector         = menu.show_inspector
    editor_settings.show_project_inspector = menu.show_project_inspector
    editor_settings.show_project           = menu.show_project
    editor_settings.show_console           = menu.show_console
    editor_settings.show_scene             = menu.show_scene
    editor_settings.show_game              = menu.show_game
    editor_settings.show_output            = menu.show_output
    editor_settings.show_hierarchy         = menu.show_hierarchy
    editor_settings.show_history           = menu.show_history
    editor_settings.has_view_state         = true

    delete(editor_settings.open_scene_guids)
    editor_settings.open_scene_guids = make([dynamic]string, context.temp_allocator)

    sm := engine.ctx_scene_manager()
    for i in 0..<sm.count {
        scene := sm.loaded[i]
        if scene == nil || !engine.sm_scene_is_valid(scene) || len(scene.path) == 0 do continue
        if guid, ok := engine.asset_db_get_guid(scene.path); ok {
            guid_str := uuid.to_string(guid, context.temp_allocator)
            append(&editor_settings.open_scene_guids, guid_str)
        }
    }

    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }
    if data, err := json.marshal(editor_settings, opts, allocator = context.temp_allocator); err == nil {
        _ = os.write_entire_file(EDITOR_SETTINGS_FILE, data)
    }
}
