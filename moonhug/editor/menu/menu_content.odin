package menu
import "core:fmt"
import im "moonhug:external/odin-imgui"
import "../inspector"
import engine "../../engine"
import "core:path/filepath"

Theme :: enum {
    Spectrum_Dark,
    Spectrum_Light,
    Dark,
    Light,
    Classic,
}

active_theme: Theme = .Spectrum_Dark

apply_theme :: proc() {
    // StyleColors* only reset COLORS, not scalar style vars. Spectrum mutates
    // scalars (rounding, borders) directly on the shared style struct, so
    // switching Spectrum -> Dark/Light must reset those scalars back to imgui
    // defaults or Spectrum's rounding leaks into the other themes.
    _reset_style_scalars_to_imgui_default()
    switch active_theme {
    case .Spectrum_Dark:  style_colors_spectrum(dark = true)  // sets its own scalars
    case .Spectrum_Light: style_colors_spectrum(dark = false)
    case .Dark:           im.StyleColorsDark();    _fix_builtin_progress_color()
    case .Light:          im.StyleColorsLight();   _fix_builtin_progress_color()
    case .Classic:        im.StyleColorsClassic(); _fix_builtin_progress_color()
    }
    // Tighter per-level tree indent (matches Unity's 14px) vs imgui's ~21px.
    im.GetStyle().IndentSpacing = 14
}

// imgui's stock themes fill ProgressBar (PlotHistogram) with a bright
// yellow that matches nothing else in them — use the theme's own accent
// (CheckMark) instead. Spectrum sets its own.
@(private = "file")
_fix_builtin_progress_color :: proc() {
    s := im.GetStyle()
    s.Colors[im.Col.PlotHistogram] = s.Colors[im.Col.CheckMark]
    s.Colors[im.Col.PlotHistogramHovered] = s.Colors[im.Col.SliderGrabActive]
}

// imgui's default (StyleColorsDark) scalar values for the vars Spectrum
// overrides — restored before applying any theme so themes don't inherit each
// other's scalars.
@(private = "file")
_reset_style_scalars_to_imgui_default :: proc() {
    s := im.GetStyle()
    s.FrameRounding   = 0
    s.FrameBorderSize = 0
    s.WindowRounding  = 0
    s.PopupRounding   = 0
    s.GrabRounding    = 0
    s.TabRounding     = 4 // imgui default is non-zero (4)
}

set_theme :: proc(theme: Theme) {
    active_theme = theme
    apply_theme()
}

quit_requested := false

// Window menu, Unity's layout: General holds the everyday views in Unity's
// order, domain submenus (Animation) follow. The undo History view lives
// under Edit, right below Undo/Redo (Unity's Edit > Undo History).
//
// Entries are OPEN commands, not toggles (Unity): selecting one shows the
// view and fronts its dock tab. Windows close from the tab's X button,
// which writes the same show_* flag through Begin's p_open pointer.
// Shortcuts match Unity (Ctrl+1..6 = Cmd+1..6 on macOS): Scene, Game,
// Inspector, Hierarchy, Project, Animation, and Cmd+Shift+C for Console.

show_scene := true
show_game := true
show_inspector := true
show_project_inspector := true
show_hierarchy := true
show_project := true
show_console := true
show_output := true
show_history := false
show_animation := false
show_playable_graph := false

@(private = "file")
_open_window :: proc(show: ^bool, title: cstring) {
	show^ = true
	im.SetWindowFocusStr(title)
}

@(menu_item={path="Window/General/Scene", order=0, shortcut="Ctrl+1"})
window_menu_scene :: proc() { _open_window(&show_scene, "Scene") }

@(menu_item={path="Window/General/Game", order=1, shortcut="Ctrl+2"})
window_menu_game :: proc() { _open_window(&show_game, "Game") }

@(menu_item={path="Window/General/Inspector", order=2, shortcut="Ctrl+3"})
window_menu_inspector :: proc() { _open_window(&show_inspector, "Inspector") }

@(menu_item={path="Window/General/Hierarchy", order=4, shortcut="Ctrl+4"})
window_menu_hierarchy :: proc() { _open_window(&show_hierarchy, "Hierarchy") }

@(menu_item={path="Window/General/Project", order=5, shortcut="Ctrl+5"})
window_menu_project :: proc() { _open_window(&show_project, "Project") }

@(menu_item={path="Window/General/Project Inspector", order=6, shortcut="Ctrl+Alt+5"})
window_menu_project_inspector :: proc() { _open_window(&show_project_inspector, "Project Inspector") }

@(menu_item={path="Window/General/Console", order=7, shortcut="Ctrl+Shift+C"})
window_menu_console :: proc() { _open_window(&show_console, "Console") }

@(menu_item={path="Window/General/Output", order=8, shortcut=""})
window_menu_output :: proc() { _open_window(&show_output, "Output") }

@(menu_item={path="Edit/Undo History", order=-98, shortcut=""})
window_menu_history :: proc() { _open_window(&show_history, "History") }

@(menu_item={path="Window/Animation/Animation", order=0, shortcut="Ctrl+6"})
window_menu_animation :: proc() { _open_window(&show_animation, "Animation") }

@(menu_item={path="Window/Animation/Playable Graph", order=1, shortcut=""})
window_menu_playable_graph :: proc() { _open_window(&show_playable_graph, "Playable Graph") }

@(menu_item={path="File/Save", order=0, shortcut="Ctrl+S"})
file_save_menu :: proc()
{
    inspector.save_to_file()
}

@(menu_separator={path="File", order=5})
file_separator_menu :: proc() {}

@(menu_separator={path="Window", order=-7})
file_separator_menu2 :: proc() {}

@(menu_item={path="File/Quit", order=10, shortcut="Alt+F4"})
file_quit_menu :: proc() { quit_requested = true }

@(menu_item={path="Assets/Refresh AssetDB", order=0, shortcut=""})
refresh_asset_db_menu :: proc() {
    engine.asset_db_refresh()
}

show_about := false

@(menu_item={path="Help/About", order=1000, shortcut=""})
help_about_menu :: proc() {
    show_about = true
}

// Diagnostics for the "keyboard input dies until restart" bug — see
// editor/view_input_debug.odin. Mouse-only operable on purpose.
@(menu_toggle={path="Help/Input Debug", order=999})
show_input_debug := false

@(menu_item={path="Window/Theme/Spectrum Dark", order=-14, shortcut=""})
menu_item_view_theme_spectrum_dark :: proc() {
    set_theme(.Spectrum_Dark)
}

@(menu_item={path="Window/Theme/Spectrum Light", order=-13, shortcut=""})
menu_item_view_theme_spectrum_light :: proc() {
    set_theme(.Spectrum_Light)
}

@(menu_item={path="Window/Theme/Dark", order=-12, shortcut=""})
menu_item_view_theme_dark :: proc() {
    set_theme(.Dark)
}

@(menu_item={path="Window/Theme/Light", order=-11, shortcut=""})
menu_item_view_theme_light :: proc() {
    set_theme(.Light)
}

@(menu_item={path="Window/Theme/Classic", order=-10, shortcut=""})
menu_item_view_theme_classic :: proc() {
    set_theme(.Classic)
}
