package scenarios

// The mhgui Shape in a real editor: made from the GameObject menu, it draws
// with the package's shape material and no setup, and its fields reach the
// shader (the Scene window's picture changes with them).

import "core:fmt"
import "core:testing"

@(private = "file")
_set :: proc(r: ^Run, object, component, path, value: string) {
	call(r, "set_property", fmt.tprintf(`{{"name":%q,"component":%q,"path":%q,"value":%q}}`, object, component, path, value))
}

@(test)
ui_shape :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	for file in ([]string{"white.png", "shaders/ui_shape.glsl", "materials/Shape.mat"}) {
		project_copy(r, fmt.tprintf("plugins/mhgui/assets/%s", file), fmt.tprintf("assets/%s", file))
		project_copy(r, fmt.tprintf("plugins/mhgui/assets/%s.meta", file), fmt.tprintf("assets/%s.meta", file))
	}
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)

	call(r, "invoke_menu", `{"path":"GameObject/UI/Shape"}`)
	frames(r, 3)
	testing.expectf(t, has_string(at(call(r, "editor_state"), "selection"), "Shape"), "the menu made a Shape and selected it")
	_set(r, "Shape", "RectTransform", "size_delta", "[320, 180]")
	_set(r, "Shape", "Shape", "graphic.color", "[0.2, 0.5, 1, 1]")
	_set(r, "Shape", "Shape", "corner_radius", "[40, 40, 8, 8]")
	_set(r, "Shape", "Shape", "border_width", "6")
	_set(r, "Shape", "Shape", "border_color", "[1, 1, 1, 1]")
	_set(r, "Shape", "Shape", "gradient", "true")
	_set(r, "Shape", "Shape", "gradient_color", "[0.6, 0.1, 0.8, 1]")
	_set(r, "Shape", "Shape", "gradient_angle", "90")
	_set(r, "Shape", "Shape", "shadow.color", "[0, 0, 0, 0.6]")
	_set(r, "Shape", "Shape", "shadow.offset", "[10, -14]")
	_set(r, "Shape", "Shape", "shadow.blur", "18")
	_set(r, "Shape", "Shape", "inner_shadow.color", "[0, 0, 0, 0.5]")
	frames(r, 3)

	two_d, has := item_rect(r, "Scene", "2D")
	if testing.expect(t, has, "the 2D button") {
		click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
		frames(r, 3)
	}
	call(r, "run_command", `{"command":"Edit/Frame Selected"}`)
	frames(r, 20)
	call(r, "screenshot", `{"target":"scene","max_size":900}`)
	call(r, "screenshot", `{"target":"window","window":"Inspector","max_size":900}`)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
