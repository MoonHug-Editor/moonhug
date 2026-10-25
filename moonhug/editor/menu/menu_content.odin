package menu
import im "moonhug:external/odin-imgui"
import "moonhug:libs/log"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/icons"
import "core:strings"

Theme :: enum {
    Spectrum_Dark,
    Spectrum_Light,
    Dark,
    Light,
    Classic,
    Photoshop, // theme_community.odin from here on
    Unreal,
    Deep_Dark,
    Dracula,
    Catppuccin_Mocha,
    Paper_And_Ink,
}

active_theme: Theme = .Spectrum_Dark

apply_theme :: proc() {
    // StyleColors* only reset COLORS, not scalar style vars. Every theme here
    // mutates scalars (rounding, borders, padding) on the shared style struct,
    // so the whole struct goes back to imgui's defaults first or one theme's
    // scalars leak into the next.
    _reset_style_to_imgui_default()
    switch active_theme {
    case .Spectrum_Dark:    style_colors_spectrum(dark = true)
    case .Spectrum_Light:   style_colors_spectrum(dark = false)
    case .Dark:             im.StyleColorsDark();    _fix_builtin_progress_color()
    case .Light:            im.StyleColorsLight();   _fix_builtin_progress_color()
    case .Classic:          im.StyleColorsClassic(); _fix_builtin_progress_color()
    case .Photoshop:        style_colors_photoshop()
    case .Unreal:           style_colors_unreal()
    case .Deep_Dark:        style_colors_deep_dark()
    case .Dracula:          style_colors_dracula()
    case .Catppuccin_Mocha: style_colors_catppuccin_mocha()
    case .Paper_And_Ink:    style_colors_paper_and_ink()
    }
    s := im.GetStyle()
    // Tighter per-level tree indent (matches Unity's 14px) vs imgui's ~21px.
    s.IndentSpacing = 14
    // No collapse triangle before a window's title or a dock node's tabs
    // (Unity has none; tabs start at the panel edge), and no close-all button
    // on a dock node: closing every docked view at once is a click away from
    // the tab bar and rarely wanted. Each tab keeps its own X.
    s.WindowMenuButtonPosition = .None
    s.DockingNodeHasCloseButton = false
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

// imgui's default style, captured on the first apply (nothing touches the
// style before the startup apply_theme) and written back before every theme
// so themes never inherit each other's scalars.
@(private = "file") _default_style: im.Style
@(private = "file") _default_style_captured: bool

@(private = "file")
_reset_style_to_imgui_default :: proc() {
    s := im.GetStyle()
    if !_default_style_captured {
        _default_style = s^
        _default_style_captured = true
    }
    s^ = _default_style
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

show_game := true

@(private = "file")
_open_window :: proc(show: ^bool, title: cstring) {
	show^ = true
	im.SetWindowFocusStr(title)
}

// The open flag behind a built-in view's window title, so the tab menu can
// close the tab it is opened on. Plugin windows keep their own list
// (window/window.odin), so this returns nil for them. Views match by the
// text after ###, the window's id: the label before it changes, a star while
// the view's file has unsaved changes.
view_show_flag :: proc(title: cstring) -> ^bool {
	id := _window_id(string(title))
	for v in builtin_views() do if _window_id(string(v.title)) == id do return v.flag
	return nil
}

// A view that exists once, opened by its flag: the Game view. Every other
// view is a window instance (editor/window).
Builtin_View :: struct {
	title: cstring,
	flag:  ^bool,
}

builtin_views :: proc() -> []Builtin_View {
	return _builtin_views[:]
}

@(private = "file")
_builtin_views := [?]Builtin_View{
	{icons.TITLE_GAME, &show_game},
}

@(private = "file")
_window_id :: proc(title: string) -> string {
	if i := strings.last_index(title, "###"); i >= 0 do return title[i + 3:]
	return title
}


@(menu_item={path="Window/General/Scene", order=0, shortcut="Ctrl+1"})
window_menu_scene :: proc() { wnd.open("Scene") }

@(menu_item={path="Window/General/Game", order=1, shortcut="Ctrl+2"})
window_menu_game :: proc() { _open_window(&show_game, icons.TITLE_GAME) }

// The views are window instances (editor/window). The engine declares the
// Inspector and the Hierarchy, so their items are off without it.
@(menu_item={path="Window/General/Inspector", order=2, shortcut="Ctrl+3", enabled=_inspector_registered})
window_menu_inspector :: proc() { wnd.open("Inspector") }

_inspector_registered :: proc() -> bool { return wnd.is_registered("Inspector") }

@(menu_item={path="Window/General/Hierarchy", order=4, shortcut="Ctrl+4", enabled=_hierarchy_registered})
window_menu_hierarchy :: proc() { wnd.open("Hierarchy") }

_hierarchy_registered :: proc() -> bool { return wnd.is_registered("Hierarchy") }

@(menu_item={path="Window/General/Project", order=5, shortcut="Ctrl+5"})
window_menu_project :: proc() { wnd.open("Project") }

@(menu_item={path="Window/General/Project Inspector", order=6, shortcut="Ctrl+Alt+5"})
window_menu_project_inspector :: proc() { wnd.open("Project Inspector") }

@(menu_item={path="Window/General/Console", order=7, shortcut="Ctrl+Shift+C"})
window_menu_console :: proc() { wnd.open("Console") }

@(menu_item={path="Window/General/Workspace", order=10, shortcut=""})
window_menu_workspace :: proc() { wnd.open("workspace") }

@(menu_item={path="Window/General/Output", order=8, shortcut=""})
window_menu_output :: proc() { wnd.open("Output") }

@(menu_item={path="Window/General/Background Tasks", order=9, shortcut=""})
window_menu_background_tasks :: proc() { background_tasks_requested = true }

// Set by Window ▸ General ▸ Background Tasks. The status bar shows its
// Background Tasks panel on the next frame and clears it.
background_tasks_requested := false

@(menu_item={path="Edit/Undo History", order=-98, shortcut=""})
window_menu_history :: proc() { wnd.open("History") }

// The animation plugin declares both windows, so the items are off without it.
@(menu_item={path="Window/Animation/Animation", order=0, shortcut="Ctrl+6", enabled=_animation_registered})
window_menu_animation :: proc() { wnd.open("Animation") }

_animation_registered :: proc() -> bool { return wnd.is_registered("Animation") }

@(menu_item={path="Window/Animation/Playable Graph", order=1, shortcut="", enabled=_playable_graph_registered})
window_menu_playable_graph :: proc() { wnd.open("Playable Graph") }

_playable_graph_registered :: proc() -> bool { return wnd.is_registered("Playable Graph") }

@(menu_item={path="File/Save", order=0, shortcut="Ctrl+S"})
file_save_menu :: proc()
{
    // Every open document with unsaved edits: scenes, assets, the Shader
    // Graph's and the Render Pipeline's files (session/documents.odin). One
    // shortcut for all of them, and a view's tab menu saves its own.
    saved, failed := session.documents_save_all()
    if failed > 0 do log.errorf("[Save] %d of %d unsaved files could not be saved, see above", failed, saved + failed)
}

@(menu_separator={path="File", order=5})
file_separator_menu :: proc() {}

@(menu_separator={path="Window", order=-7})
file_separator_menu2 :: proc() {}

@(menu_item={path="File/Quit", order=10, shortcut="Alt+F4"})
file_quit_menu :: proc() { quit_requested = true }

@(menu_item={path="Assets/Refresh AssetDB", order=0, shortcut=""})
refresh_asset_db_menu :: proc() {
    asset_pipeline.asset_db_refresh()
}

show_about := false

@(menu_item={path="Help/About", order=1000, shortcut=""})
help_about_menu :: proc() {
    show_about = true
}

// Diagnostics for the "keyboard input dies until restart" bug — see
// editor/view_input_debug.odin. Mouse-only operable on purpose.
@(menu_item={path="Help/Input Debug", order=999})
show_input_debug := false

// The theme list is a RADIO group: every item sets active_theme, and its
// checked predicate reports whether it is the one currently set. No exclusive
// menu kind — an action plus a tick predicate is what one-of-N is.

@(menu_item={path="Window/Theme/Spectrum Dark", order=-14, shortcut="", checked=theme_is_spectrum_dark})
menu_item_view_theme_spectrum_dark :: proc() {
    set_theme(.Spectrum_Dark)
}
theme_is_spectrum_dark :: proc() -> bool { return active_theme == .Spectrum_Dark }

@(menu_item={path="Window/Theme/Spectrum Light", order=-13, shortcut="", checked=theme_is_spectrum_light})
menu_item_view_theme_spectrum_light :: proc() {
    set_theme(.Spectrum_Light)
}
theme_is_spectrum_light :: proc() -> bool { return active_theme == .Spectrum_Light }

@(menu_item={path="Window/Theme/Dark", order=-12, shortcut="", checked=theme_is_dark})
menu_item_view_theme_dark :: proc() {
    set_theme(.Dark)
}
theme_is_dark :: proc() -> bool { return active_theme == .Dark }

@(menu_item={path="Window/Theme/Light", order=-11, shortcut="", checked=theme_is_light})
menu_item_view_theme_light :: proc() {
    set_theme(.Light)
}
theme_is_light :: proc() -> bool { return active_theme == .Light }

@(menu_item={path="Window/Theme/Classic", order=-10, shortcut="", checked=theme_is_classic})
menu_item_view_theme_classic :: proc() {
    set_theme(.Classic)
}
theme_is_classic :: proc() -> bool { return active_theme == .Classic }

@(menu_item={path="Window/Theme/Photoshop", order=-9, shortcut="", checked=theme_is_photoshop})
menu_item_view_theme_photoshop :: proc() {
    set_theme(.Photoshop)
}
theme_is_photoshop :: proc() -> bool { return active_theme == .Photoshop }

@(menu_item={path="Window/Theme/Unreal", order=-8, shortcut="", checked=theme_is_unreal})
menu_item_view_theme_unreal :: proc() {
    set_theme(.Unreal)
}
theme_is_unreal :: proc() -> bool { return active_theme == .Unreal }

@(menu_item={path="Window/Theme/Deep Dark", order=-7, shortcut="", checked=theme_is_deep_dark})
menu_item_view_theme_deep_dark :: proc() {
    set_theme(.Deep_Dark)
}
theme_is_deep_dark :: proc() -> bool { return active_theme == .Deep_Dark }

@(menu_item={path="Window/Theme/Dracula", order=-6, shortcut="", checked=theme_is_dracula})
menu_item_view_theme_dracula :: proc() {
    set_theme(.Dracula)
}
theme_is_dracula :: proc() -> bool { return active_theme == .Dracula }

@(menu_item={path="Window/Theme/Catppuccin Mocha", order=-5, shortcut="", checked=theme_is_catppuccin_mocha})
menu_item_view_theme_catppuccin_mocha :: proc() {
    set_theme(.Catppuccin_Mocha)
}
theme_is_catppuccin_mocha :: proc() -> bool { return active_theme == .Catppuccin_Mocha }

@(menu_item={path="Window/Theme/Paper And Ink", order=-4, shortcut="", checked=theme_is_paper_and_ink})
menu_item_view_theme_paper_and_ink :: proc() {
    set_theme(.Paper_And_Ink)
}
theme_is_paper_and_ink :: proc() -> bool { return active_theme == .Paper_And_Ink }
