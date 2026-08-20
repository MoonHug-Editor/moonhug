#+build !darwin
package editor

// Non-macOS stub; see dock_icon_darwin.odin. On Windows/Linux the window/task
// bar icon would instead come from rl.SetWindowIcon (or an .exe resource).
set_dock_icon :: proc(image_path: string) {
}
