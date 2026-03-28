package engine_editor

import "../engine"
import im "../../external/odin-imgui"
import "core:path/filepath"

@(property_drawer={type=engine.Scene, priority = 10})
draw_scene_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	scene := cast(^engine.Scene)(ptr)
	if scene == nil do return
	if im.Button("Open Scene") {
		engine.scene_set_active(scene)
	}
}
