package plugin_example_editor

// Editor-only half of plugin_example: compiled into the editor binary, never
// the app. May import engine, imgui and the editor's subpackages (menu,
// inspector, undo) — never the editor root (docs/Plugins.md layering rule).

import "moonhug:engine/log"
import im "moonhug:external/odin-imgui"
import wnd "moonhug:editor/window"

@(menu_item={path="Tools/Plugin Example/Log", shortcut=""})
plugin_example_menu :: proc() {
	log.info("[plugin_example] Hello from the plugin's editor package!")
}

// Editor-window demo (editor/window, docs/Plugins.md): the attribute declares
// the window, a @(menu_item) opens it by id - Unity's [MenuItem] + GetWindow
// shape. width/height apply on first show, before imgui.ini has an entry.
@(editor_window={id="plugin_example", title="Plugin Example", width=420, height=200})
plugin_example_window_draw :: proc() {
	im.TextWrapped("A plugin-owned editor window. Dock me anywhere - " +
		"position persists in imgui.ini. Close and reopen from " +
		"Window/Plugin Example.")
}

@(menu_item={path="Window/Plugin Example", shortcut=""})
plugin_example_window :: proc() {
	wnd.open("plugin_example")
}
