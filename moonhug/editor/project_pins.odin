package editor

// Pinned folders of the Project window: a short list above the folder tree,
// one click from anywhere. Any folder can be pinned, a package's row too.
// Kept per developer in the editor settings. A pin whose folder is gone is
// not shown, and comes back with the folder.

import "base:runtime"
import "core:strings"
import assets "moonhug:libs/assets"
import "moonhug:editor/keymap"

// Whether `path` is a folder the Project window shows: one of the project,
// or a package's assets folder.
project_is_folder :: proc(path: string) -> bool {
	if path == "" || path == _PROJECT_PACKAGES_PATH do return false
	return path == projectWindowData.rootPath || project_path_is_package_root(path) || assets.asset_db_is_dir(path)
}

project_pin_is :: proc(path: string) -> bool {
	for p in editor_settings.project_pins do if p == path do return true
	return false
}

project_pin_toggle :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	for p, i in editor_settings.project_pins do if p == path {
		delete(p)
		ordered_remove(&editor_settings.project_pins, i)
		return
	}
	append(&editor_settings.project_pins, strings.clone(path))
}

// A folder moved or got another name: a pin on it, or on one under it,
// follows.
project_pins_moved :: proc(old, new: string) {
	context.allocator = runtime.default_allocator()
	under := strings.concatenate({old, "/"}, context.temp_allocator)
	for &p in editor_settings.project_pins {
		moved: string
		switch {
		case p == old:                     moved = strings.clone(new)
		case strings.has_prefix(p, under): moved = strings.concatenate({new, p[len(old):]})
		case:                              continue
		}
		delete(p)
		p = moved
	}
}

// The selected folder, for the two menu items: "" when the selection is not
// one folder.
@(private = "file")
_pin_target :: proc() -> string {
	if sel_proj_count() != 1 do return ""
	sel := projectWindowData.selectedFile
	return sel if project_is_folder(sel) else ""
}

@(private)
_pin_can :: proc() -> bool {
	t := _pin_target()
	return t != "" && !project_pin_is(t)
}

@(private)
_unpin_can :: proc() -> bool {
	t := _pin_target()
	return t != "" && project_pin_is(t)
}

@(private)
_pin_enabled :: proc() -> bool {
	return _pin_target() != "" || keymap.disabled("Select one folder")
}

@(menu_item = {path = "Assets/Pin Folder", order = -64, enabled = _pin_enabled, visible = _pin_can, help = "Keeps the selected folder in the list above the Project window's folder tree"})
project_menu_pin :: proc() {
	if t := _pin_target(); t != "" do project_pin_toggle(t)
}

@(menu_item = {path = "Assets/Unpin Folder", order = -64, enabled = _pin_enabled, visible = _unpin_can, help = "Takes the selected folder out of the pinned list"})
project_menu_unpin :: proc() {
	if t := _pin_target(); t != "" do project_pin_toggle(t)
}
