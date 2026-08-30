package plugin_example_editor

// Editor-only half of plugin_example: compiled into the editor binary, never
// the app. May import engine, imgui and the editor's subpackages (menu,
// inspector, undo) — never the editor root (docs/Plugins.md layering rule).

import "moonhug:engine/log"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import wnd "moonhug:editor/window"
import plugin_example "moonhug:packages/plugin_example"

@(menu_item={path="Tools/Plugin Example/Log", shortcut=""})
plugin_example_menu :: proc() {
	log.info("[plugin_example] Hello from the plugin's editor package!")
}

// Inspector-funnel demo (docs/Plugins.md): a wrapper around Spinner's
// inspector — the default fields keep drawing, the package adds a row
// under them. order=1 runs after editor_init (order=0).
@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
plugin_example_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(plugin_example.Spinner), _spinner_inspector)
}

_spinner_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx) // the default Spinner fields
	spinner := cast(^plugin_example.Spinner)ctx.ptr
	z := abs(spinner.speed.z)
	im.TextDisabled("full z turn: %.2f s", z > 0.01 ? 360.0 / z : 0.0)
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
