package scenarios

// The Measure tool (plugins/engine/editor/scene_tools/measure_tool.odin) in a
// real Scene window: M picks it, a drag measures without selecting, and in
// 2D over a UI canvas the distance is in pixels.

import "core:fmt"
import "core:testing"

@(test)
measure_tool_measures_in_the_scene_window :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"GameObject/UI/Canvas"}`)
	frames(r, 3)
	scene, shown := window_rect(r, "Scene")
	if !testing.expect(t, shown, "the Scene window is open") do return

	// M picks the tool, and a drag measures: the selection (the new canvas)
	// stays, where a box select would have changed it.
	selection :: proc(r: ^Run) -> string {
		return fmt.tprint(at(call(r, "editor_state"), "selection"))
	}
	before := selection(r)
	call(r, "input", `{"steps":[{"type":"key","name":"M"},{"type":"key","name":"M","down":false},{"type":"wait","frames":2}]}`)
	cx, cy := scene.x + scene[2] * 0.5, scene.y + scene[3] * 0.5
	drag_mouse(r, cx - 150, cy + 80, cx + 120, cy - 60)
	frames(r, 2)
	testing.expectf(t, selection(r) == before, "a measuring drag keeps the selection: %v, was %v", selection(r), before)
	call(r, "screenshot", `{"target":"window","window":"Scene","max_size":640}`)

	// 2D, over the canvas (from the origin up and right): pixels.
	two_d, has := item_rect(r, "Scene", "2D")
	if !testing.expect(t, has, "the 2D button") do return
	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 4)
	drag_mouse(r, cx + 40, cy - 30, cx + 240, cy - 130)
	frames(r, 2)
	call(r, "screenshot", `{"target":"window","window":"Scene","max_size":640}`)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
