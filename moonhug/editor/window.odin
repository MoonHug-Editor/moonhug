package editor

import gfx "moonhug:libs/gfx"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "menu"
import wnd "window"
import "moonhug:editor/command_palette"
import "moonhug:editor/handles"
import "moonhug:editor/keymap"
import "moonhug:editor/session"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:libs/log"
import "moonhug:libs/gizmos"

MAIN_WINDOW_TITLE :: "MoonHug Editor"
VERSION :: #load("../version", string)

// The version file ends in a newline: the number alone.
version_text :: proc() -> string {
	return strings.trim_space(VERSION)
}

// The main window's title and the app menu's: the editor and its version.
main_window_title :: proc() -> string {
	return fmt.tprintf("%s %s", MAIN_WINDOW_TITLE, version_text())
}

// Per-DEVELOPER editor state, never committed (Unity's UserSettings): window
// geometry, which scenes and windows were open, panel visibility, theme, grid
// and snap choices, the selected run config. All of it is one person's working
// setup — sharing it means every developer's git status is dirty after a run
// and someone else's window position lands in an unrelated commit.
//
// The other half is core.PROJECT_SETTINGS_DIR: settings about the PROJECT,
// committed, read by the game too (docs/core/Plugins.md "Project settings").
EDITOR_SETTINGS_FILE :: core.USER_SETTINGS_DIR + "/editor_settings.json"

// Read once at startup to migrate a pre-split checkout, then ignored.
LEGACY_EDITOR_SETTINGS_FILE :: core.PROJECT_SETTINGS_DIR + "/editor_settings.json"

EditorSettings :: struct {
    width:                    i32,
    height:                   i32,
    x:                        i32,
    y:                        i32,
    theme:                    menu.Theme,
    open_scene_guids:         [dynamic]string,
    recent_scene_guids:       [dynamic]string,          // File/Recent Scenes, newest first (recent_scenes.odin)
    open_window_ids:          [dynamic]string,          // plugin editor windows open last session (window/window.odin)
    has_window_state:         bool,                     // open_window_ids is saved: false on a first run
    scene_overlays:           [dynamic]Overlay_Setting, // dockable overlay placement (dock.odin)
    grid:                     Grid_Settings,            // scene grid (window_scene.odin)
    snap:                     Snap_Settings,            // gizmo snapping (window_scene.odin)
    run_config:               string,                   // Play button's selected run config (window_toolbar.odin), "pkg/name"
    sim_host:                 string,                   // Simulate's host package name (simulate.odin), e.g. "app"
    project_settings_tab:     string,                   // Project Settings window's selected section (project_settings.odin)
    project_zoom:             f32,                      // Project window zoom: 0 = list, >0 = thumbnail grid (window_project.odin)
    scene_ortho:              bool,                     // Scene window projection (window_scene.odin)
    scene_2d:                 bool,                     // Scene window 2D mode (window_scene.odin)
    scene_mode:               core.View_Mode,           // Scene window shading mode (window_scene.odin)
    scene_gizmos_off:         bool,                     // Scene window Gizmos toggle, inverted so an older file keeps it on (gizmos.scene_gizmos)
    gizmo_icon_px:            f32,                      // gizmo settings' Icon Size, 0 = the default
    gizmo_hidden_icons:       [dynamic]string,          // component types whose icon the gizmo settings hide
    gizmo_hidden_gizmos:      [dynamic]string,          // component types whose gizmo the gizmo settings hide
    selection:                Persisted_Selection,      // the selection at quit (selection_persist.odin)
    windows:                  [dynamic]Persisted_Window, // every window's lock and saved state (selection_persist.odin)
    command_palette_recent:   []command_palette.Recent, // each palette mode's recently run rows, newest first
    command_args:             map[string]string,        // each command with arguments' last values, JSON by command id (adjust_last.odin)
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
            _sv_plain.cam_ortho = editor_settings.scene_ortho
            gizmos.scene_gizmos = !editor_settings.scene_gizmos_off
            if editor_settings.gizmo_icon_px > 0 do handles.icon_px = editor_settings.gizmo_icon_px
            for name in editor_settings.gizmo_hidden_icons do gizmos.gizmo_type_set(name, .Icon, false)
            for name in editor_settings.gizmo_hidden_gizmos do gizmos.gizmo_type_set(name, .Gizmo, false)
            if editor_settings.scene_2d do _sv_plain.pending_2d = true
            _sv_plain.view_mode = editor_settings.scene_mode
            command_palette.recent_load(editor_settings.command_palette_recent)
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
    os.make_directory(core.USER_SETTINGS_DIR)
    pos := gfx.window_position()
    size := gfx.window_size()
    editor_settings.width  = size.x
    editor_settings.height = size.y
    editor_settings.x      = pos.x
    editor_settings.y      = pos.y
    editor_settings.theme  = menu.active_theme

    editor_settings.has_window_state       = true

    // Plugin windows: imgui.ini keeps each instance's dock and size, not
    // whether it existed: the instance keys are what reopen them.
    delete(editor_settings.open_window_ids)
    editor_settings.open_window_ids = make([dynamic]string, context.temp_allocator)
    for key in wnd.open_keys() do append(&editor_settings.open_window_ids, key)

    overlays_capture_settings()
    editor_settings.grid = grid_settings
    editor_settings.snap = snap_settings
    editor_settings.scene_ortho = _sv_plain.pre_2d_ortho if _sv_plain.mode_2d else _sv_plain.cam_ortho
    editor_settings.scene_2d = _sv_plain.mode_2d
    editor_settings.scene_mode = _sv_plain.view_mode
    editor_settings.scene_gizmos_off = !gizmos.scene_gizmos
    editor_settings.gizmo_icon_px = handles.icon_px
    delete(editor_settings.gizmo_hidden_icons)
    delete(editor_settings.gizmo_hidden_gizmos)
    editor_settings.gizmo_hidden_icons = gizmos.gizmo_types_hiding(.Icon)
    editor_settings.gizmo_hidden_gizmos = gizmos.gizmo_types_hiding(.Gizmo)

    // The selection and the inspector locks, named so they resolve next run.
    selection_persist_capture()

    // The palette's own copy, temp: the loaded list stays unfreed until exit.
    editor_settings.command_palette_recent = command_palette.recent_saved()

    // The last values of every command with arguments. Temp, as above.
    editor_settings.command_args = make(map[string]string, context.temp_allocator)
    for c in keymap.commands() {
        if args := keymap.command_args_json(c); args != nil do editor_settings.command_args[c.id] = string(args)
    }

    delete(editor_settings.open_scene_guids)
    editor_settings.open_scene_guids = make([dynamic]string, context.temp_allocator)

    for path in session.document_open_paths() {
        if guid, ok := assets.asset_db_get_guid(path); ok {
            guid_str := uuid.to_string(guid, context.temp_allocator)
            append(&editor_settings.open_scene_guids, guid_str)
        }
    }

    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
        // A window's saved state and the command arguments are maps: sorted,
        // the file reads the same whenever it is written.
        sort_maps_by_key = true,
    }
    if data, err := json.marshal(editor_settings, opts, allocator = context.temp_allocator); err == nil {
        _ = os.write_entire_file(EDITOR_SETTINGS_FILE, core.json_canonicalize_floats(data, context.temp_allocator))
    }
}
