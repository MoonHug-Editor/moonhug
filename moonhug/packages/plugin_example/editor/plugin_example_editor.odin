package plugin_example_editor

// Editor-only half of plugin_example: compiled into the editor binary, never
// the app. May import engine, imgui and the editor's subpackages (menu,
// inspector, undo) — never the editor root (docs/Plugins.md layering rule).

import "moonhug:engine/log"

@(menu_item={path="Tools/Plugin Example/Log", shortcut=""})
plugin_example_menu :: proc() {
	log.info("[plugin_example] Hello from the plugin's editor package!")
}
