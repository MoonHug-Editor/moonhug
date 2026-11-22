package scenarios

// The mhgui sample's demo scene in a real editor: it opens with no error and
// the Game window draws it. The picture is for the eye: the UiShape cells,
// the UiMask cells with a circle, a bar and a line of text cut to the
// viewport (round, turned, a circle, soft, one in another), and the rows
// under them.

import "core:encoding/json"
import "core:fmt"
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
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
