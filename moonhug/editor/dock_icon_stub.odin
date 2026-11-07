#+build !darwin
package editor

// Non-macOS stub; see dock_icon_darwin.odin. On Windows/Linux the window/task
// bar icon would instead come from rl.SetWindowIcon (or an .exe resource).
set_dock_icon :: proc(image_path: string) {
}

// The application menu is a macOS thing; see dock_icon_darwin.odin.
set_app_menu_title :: proc(title: string) {
}

// Cmd+W on SDL's macOS menu bar; see dock_icon_darwin.odin.
drop_window_close_key :: proc() {
}
