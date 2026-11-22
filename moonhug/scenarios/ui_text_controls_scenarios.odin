package scenarios

// The InputField and the Dropdown of mhgui's text integration in a real
// editor: made from the GameObject menu with every node they need, shown in
// the inspector, undone and redone as one step each.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

@(test)
ui_text_controls_from_the_menu :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	for file in ([]string{
		"plugins/mhgui/assets/white.png",
		"plugins/mhgui/assets/shaders/ui_shape.glsl",
		"plugins/mhgui/assets/materials/UiShape.mat",
		"plugins/text/assets/Roboto-Medium.ttf",
		"plugins/text/assets/shaders/text_sdf.glsl",
		"plugins/text/assets/materials/TextSDF.mat",
	}) {
		name := file[len("plugins/"):]
		project_copy(r, file, fmt.tprintf("assets/%s", name))
		project_copy(r, fmt.tprintf("%s.meta", file), fmt.tprintf("assets/%s.meta", name))
	}
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	// How many objects have `name` in their name: "Text" counts Text Area too.
	count :: proc(r: ^Run, name: string) -> int {
		objects, _ := at(call(r, "list_objects", fmt.tprintf(`{{"name":%q}}`, name)), "objects").(json.Array)
		return len(objects)
	}

	call(r, "invoke_menu", `{"path":"GameObject/UI/Input Field"}`)
	frames(r, 3)
	testing.expectf(t, has_string(at(call(r, "editor_state"), "selection"), "Input Field"), "the menu made an Input Field and selected it")
	testing.expect(t, count(r, "Text Area") == 1 && count(r, "Placeholder") == 1 && count(r, "Text") == 2, "with its Text Area, hint and Text")
	call(r, "screenshot", `{"target":"window","window":"Inspector","max_size":900}`)
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	testing.expect(t, count(r, "Input Field") == 0 && count(r, "Text Area") == 0, "one undo takes the whole field away")
	call(r, "invoke_menu", `{"path":"Edit/Redo"}`)
	frames(r, 3)
	testing.expect(t, count(r, "Input Field") == 1 && count(r, "Text") == 2, "and redo brings it back")

	call(r, "select", `{"name":"Canvas"}`)
	frames(r, 2)
	call(r, "invoke_menu", `{"path":"GameObject/UI/Dropdown"}`)
	frames(r, 3)
	testing.expectf(t, has_string(at(call(r, "editor_state"), "selection"), "Dropdown"), "the menu made a Dropdown and selected it")
	testing.expect(t, count(r, "Template") == 1 && count(r, "Item") == 2 && count(r, "Item Label") == 1, "with its Template, one Item and the Item's label")
	testing.expect(t, count(r, "Canvas") == 1, "in the canvas that was selected")
	call(r, "screenshot", `{"target":"window","window":"Inspector","max_size":900}`)

	// The Scene window's picture of both, for the eye.
	if two_d, has := item_rect(r, "Scene", "2D"); has {
		click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
		frames(r, 3)
	}
	// The field moved up, off the dropdown made at the same place.
	call(r, "set_property", `{"name":"Input Field","component":"RectTransform","path":"anchored_position","value":"[0, 60, 0]"}`)
	call(r, "select", `{"name":"Input Field"}`)
	call(r, "run_command", `{"command":"Edit/Frame Selected"}`)
	frames(r, 20)
	call(r, "select", `{"name":"Main"}`)
	frames(r, 3)
	call(r, "screenshot", `{"target":"scene","max_size":900}`)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
