package editor

import gfx "../engine/gfx"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "menu"
import wnd "window"
import "../engine"
import "../engine/log"

WINDOW_TITLE :: "MoonHug Editor"
VERSION :: #load("../version", string)

// Per-DEVELOPER editor state, never committed (Unity's UserSettings): window
// geometry, which scenes and windows were open, panel visibility, theme, grid
// and snap choices, the selected run config. All of it is one person's working
// setup — sharing it means every developer's git status is dirty after a run
// and someone else's window position lands in an unrelated commit.
//
// The other half is engine.PROJECT_SETTINGS_DIR: settings about the PROJECT,
// committed, read by the game too (docs/Plugins.md "Project settings").
USER_SETTINGS_DIR :: "UserSettings"
EDITOR_SETTINGS_FILE :: USER_SETTINGS_DIR + "/editor_settings.json"

// Read once at startup to migrate a pre-split checkout, then ignored.
LEGACY_EDITOR_SETTINGS_FILE :: engine.PROJECT_SETTINGS_DIR + "/editor_settings.json"

EditorSettings :: struct {
    width:                    i32,
    height:                   i32,
    x:                        i32,
    y:                        i32,
    theme:                    menu.Theme,
    open_scene_guids:         [dynamic]string,
    open_window_ids:          [dynamic]string,          // plugin editor windows open last session (window/window.odin)
    show_inspector:           bool,
    show_project_inspector:   bool,
    show_project:             bool,
    show_console:             bool,
    show_scene:               bool,
    show_game:                bool,
    show_output:              bool,
    show_hierarchy:           bool,
    show_history:             bool,
    show_animation:           bool,
    show_playable_graph:      bool,
    has_view_state:           bool,
    scene_overlays:           [dynamic]Overlay_Setting, // dockable overlay placement (dock.odin)
    grid:                     Grid_Settings,            // scene grid (view_scene.odin)
    snap:                     Snap_Settings,            // gizmo snapping (view_scene.odin)
    run_config:               string,                   // Play button's selected run config (view_toolbar.odin), "pkg/name"
    sim_host:                 string,                   // Simulate's host package name (simulate.odin), e.g. "app"
    project_settings_tab:     string,                   // Project Settings window's selected section (project_settings.odin)
    project_zoom:             f32,                      // project view zoom: 0 = list, >0 = thumbnail grid (view_project.odin)
}

editor_settings: EditorSettings

load_editor_settings :: proc() -> (w, h, x, y: i32) {
    data, read_err := os.read_entire_file(EDITOR_SETTINGS_FILE, context.temp_allocator)
    if read_err != nil {
        // Pre-split checkout: adopt the committed file's values once. The next
        // save writes UserSettings/ and this branch stops being taken.
        data, read_err = os.read_entire_file(LEGACY_EDITOR_SETTINGS_FILE, context.temp_allocator)
        if read_err == nil {
            log.infof("[startup] migrating %q to %q", LEGACY_EDITOR_SETTINGS_FILE, EDITOR_SETTINGS_FILE)
        }
    }
    if read_err == nil {
        err := json.unmarshal(data, &editor_settings)
        if err == nil {
            // Zero grid/snap = settings file predates the field; keep code defaults.
            if editor_settings.grid.cells_count > 0 && editor_settings.grid.cell_size > 0 {
                grid_settings = editor_settings.grid
            }
            if editor_settings.snap.angle > 0 {
                snap_settings = editor_settings.snap
            }
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
                menu.show_animation         = editor_settings.show_animation
                menu.show_playable_graph    = editor_settings.show_playable_graph
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
    dx, dy, dw, dh := gfx.display_usable_bounds()
    w := i32(f32(dw) * 0.85)
    h := i32(f32(dh) * 0.85)
    gfx.set_window_geometry(dx + (dw - w) / 2, dy + (dh - h) / 2, w, h)
}

save_editor_settings :: proc() {
    os.make_directory(USER_SETTINGS_DIR)
    pos := gfx.window_position()
    size := gfx.window_size()
    editor_settings.width  = size.x
    editor_settings.height = size.y
    editor_settings.x      = pos.x
    editor_settings.y      = pos.y
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
    editor_settings.show_animation         = menu.show_animation
    editor_settings.show_playable_graph    = menu.show_playable_graph
    editor_settings.has_view_state         = true

    // Plugin windows: imgui.ini keeps their dock and size, not whether they
    // existed — the id list is what reopens them.
    delete(editor_settings.open_window_ids)
    editor_settings.open_window_ids = make([dynamic]string, context.temp_allocator)
    for id in wnd.open_ids() do append(&editor_settings.open_window_ids, id)

    overlays_capture_settings()
    editor_settings.grid = grid_settings
    editor_settings.snap = snap_settings

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
