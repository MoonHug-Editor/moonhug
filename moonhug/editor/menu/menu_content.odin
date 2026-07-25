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
    case .Dark:           im.StyleColorsDark()
    case .Light:          im.StyleColorsLight()
    case .Classic:        im.StyleColorsClassic()
    }
    // Tighter per-level tree indent (matches Unity's 14px) vs imgui's ~21px.
    im.GetStyle().IndentSpacing = 14
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

@(menu_toggle={path="View/Inspector", order=10})
show_inspector := true

@(menu_toggle={path="View/Project Inspector", order=11})
show_project_inspector := true

@(menu_toggle={path="View/Project", order=1})
show_project := true

@(menu_toggle={path="View/Console", order=2})
show_console := true

@(menu_toggle={path="View/Scene", order=3})
show_scene := true

@(menu_toggle={path="View/Game", order=4})
show_game := true

@(menu_toggle={path="View/Output", order=5})
show_output := true

@(menu_toggle={path="View/Hierarchy", order=0})
show_hierarchy := true

@(menu_toggle={path="View/History", order=6})
show_history := false

@(menu_item={path="File/Save", order=0, shortcut="Ctrl+S"})
file_save_menu :: proc()
{
    inspector.save_to_file()
}

@(menu_separator={path="File", order=5})
file_separator_menu :: proc() {}

@(menu_separator={path="View", order=-7})
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

@(menu_item={path="View/Theme/Spectrum Dark", order=-14, shortcut=""})
menu_item_view_theme_spectrum_dark :: proc() {
    set_theme(.Spectrum_Dark)
}

@(menu_item={path="View/Theme/Spectrum Light", order=-13, shortcut=""})
menu_item_view_theme_spectrum_light :: proc() {
    set_theme(.Spectrum_Light)
}

@(menu_item={path="View/Theme/Dark", order=-12, shortcut=""})
menu_item_view_theme_dark :: proc() {
    set_theme(.Dark)
}

@(menu_item={path="View/Theme/Light", order=-11, shortcut=""})
menu_item_view_theme_light :: proc() {
    set_theme(.Light)
}

@(menu_item={path="View/Theme/Classic", order=-10, shortcut=""})
menu_item_view_theme_classic :: proc() {
    set_theme(.Classic)
}
