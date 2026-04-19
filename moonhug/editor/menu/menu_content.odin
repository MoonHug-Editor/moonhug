package menu
import "core:fmt"
import im "../../../external/odin-imgui"
import "../inspector"
import engine "../../engine"
import "core:path/filepath"

Theme :: enum {
    Dark,
    Light,
    Classic,
}

active_theme: Theme

apply_theme :: proc() {
    switch active_theme {
    case .Dark:    im.StyleColorsDark()
    case .Light:   im.StyleColorsLight()
    case .Classic: im.StyleColorsClassic()
    }
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

@(menu_toggle={path="View/Scale UI for DPI (sharing)", order=5})
scale_ui_for_dpi := true

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

@(menu_item={path="Help/About MoonHug Editor", order=1000, shortcut=""})
help_about_menu :: proc() {
    show_about = true
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
