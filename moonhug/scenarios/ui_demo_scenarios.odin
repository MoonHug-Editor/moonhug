package scenarios

// The mhgui sample's demo scene in a real editor: it opens with no error and
// the Game window draws it. The picture is for the eye: the UiShape cells,
// the UiMask cells with a circle, a bar and a line of text cut to the
// viewport (round, turned, a circle, soft, one in another), and the rows
// under them.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
ui_demo_scene_opens_and_draws :: proc(t: ^testing.T) {
	r := begin(t)
	project_copy(r, "plugins/mhgui/samples/mhgui_sample/assets/ui_demo.scene", "assets/ui_demo.scene")
	project_copy(r, "plugins/mhgui/samples/mhgui_sample/assets/ui_demo.scene.meta", "assets/ui_demo.scene.meta")
	// What the scene draws with, by guid: the metas travel with the files.
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
	call(r, "open_scene", `{"path":"assets/ui_demo.scene"}`)
	frames(r, 5)
	call(r, "invoke_menu", `{"path":"Window/General/Game"}`)
	frames(r, 30)
	viewports, _ := at(call(r, "list_objects", `{"name":"Viewport"}`), "objects").(json.Array)
	testing.expect_value(t, len(viewports), 5) // the masked viewports
	call(r, "screenshot", `{"target":"game","max_size":900}`)

	// The UiMask tab of the Project Settings: the setting's row and a box
	// that describes the chosen option.
	call(r, "invoke_menu", `{"path":"Edit/Project Settings..."}`)
	frames(r, 5)
	tab, has_tab := item_rect(r, "Project Settings", "UiMask")
	if testing.expect(t, has_tab, "the Project Settings have a UiMask tab") {
		click(r, tab.x + 20, tab.y + tab[3] / 2)
		frames(r, 5)
		call(r, "screenshot", `{"target":"window","window":"Project Settings","max_size":900}`)
		// Manual Include: every shader of the project compiles again, and the
		// shaders that call ui_clip() themselves still clip.
		row, has_row := item_rect(r, "Project Settings", "shader_clip")
		if testing.expect(t, has_row, "the tab has the shader_clip row") {
			click(r, row.x + row[2] / 2, row.y + row[3] / 2)
			frames(r, 3)
			option, has_option := item_rect(r, "popup", "Manual_Include")
			if testing.expect(t, has_option, "the row lists Manual_Include") {
				click(r, option.x + 10, option.y + option[3] / 2)
				frames(r, 30)
				call(r, "screenshot", `{"target":"window","window":"Project Settings","max_size":900}`)
				call(r, "screenshot", `{"target":"game","max_size":900}`)
				entries, _ := call(r, "read_log", `{"max":500}`).(json.Array)
				compiled := false
				for e in entries do if strings.contains(as_string(at(e, "message")), "Shader clip is Manual_Include") do compiled = true
				testing.expect(t, compiled, "the change compiled the shaders again")
			}
		}
	}

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
