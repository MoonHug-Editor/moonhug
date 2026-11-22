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
		"plugins/mhgui/samples/mhgui_sample/assets/mask_heart.png",
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
	testing.expect_value(t, len(viewports), 7) // the masked viewports, the scroll view's and the sprite mask's among them
	call(r, "screenshot", `{"target":"game","max_size":900}`)

	// The scroll view, live while the game plays: the wheel over it moves
	// its content, and a drag does.
	content_y :: proc(r: ^Run) -> f64 {
		p, _ := at(call(r, "get_property", `{"name":"Content","component":"RectTransform","path":"anchored_position"}`), "value").(json.Array)
		if len(p) < 2 do return -1
		return as_f64(p[1])
	}
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 10)
	game, game_shown := window_rect(r, "Game")
	if testing.expect(t, game_shown, "the Game window is open") {
		// The scroll view's cell is the fourth of the third row: its view is
		// at canvas (250, 0). The canvas is 1800 wide across the picture: a
		// canvas unit is this many points.
		unit := game[2] / 1800
		cx := game.x + game[2] / 2 + 250 * unit
		// The Game window's picture starts under its toolbar.
		cy := game.y + game[3] / 2 + 18
		click(r, cx, cy) // the first click gives the Game window the focus
		frames(r, 5)
		testing.expectf(t, abs(content_y(r)) < 0.5, "the content starts at its top: %v", content_y(r))
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"wheel","y":-2}},{{"type":"wait","frames":6}}]}}`, cx, cy))
		wheeled := content_y(r)
		testing.expectf(t, wheeled > 40, "the wheel scrolled the content down its list: %v", wheeled)
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"down"}},{{"type":"wait","frames":2}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}}]}}`, cx, cy - 15, cx, cy - 30))
		call(r, "screenshot", `{"target":"game","max_size":900}`)
		dragged := content_y(r)
		call(r, "input", `{"steps":[{"type":"up"},{"type":"wait","frames":3}]}`)
		testing.expectf(t, dragged > wheeled + 5, "a drag up scrolled it further: %v after %v", dragged, wheeled)
	}
	// The controls cell: a click turns on the second toggle of the group,
	// which turns the first off, and a drag along the slider changes its value.
	if game_shown {
		unit := game[2] / 1800
		spot :: proc(game: [4]f64, unit, x, y: f64) -> (f64, f64) {
			return game.x + game[2] / 2 + x * unit, game.y + game[3] / 2 + 18 - y * unit
		}
		is_on :: proc(r: ^Run, name: string) -> bool {
			return as_bool(at(call(r, "get_property", fmt.tprintf(`{{"name":%q,"component":"Toggle","path":"is_on"}}`, name)), "value"))
		}
		value :: proc(r: ^Run) -> f64 {
			return as_f64(at(call(r, "get_property", `{"name":"Slider","component":"Slider","path":"value"}`), "value"))
		}
		testing.expect(t, is_on(r, "Toggle 1") && !is_on(r, "Toggle 2"), "the first toggle starts on")
		tx, ty := spot(game, unit, 500, -15)
		click(r, tx, ty)
		frames(r, 5)
		testing.expect(t, is_on(r, "Toggle 2") && !is_on(r, "Toggle 1"), "a click on the second turns it on and the first off")
		testing.expectf(t, value(r) == 60, "the slider starts at 60: %v", value(r))
		// The handle sits at 60 of 100 along the 180 wide track: the press
		// lands on it, the drag takes it to a quarter and to three quarters.
		// The handle is a few points tall and the picture's place under the
		// window's bars is not known to the point, so the press is tried a
		// little higher and lower until it takes hold.
		hx, hy := spot(game, unit, 500 - 90 + 108, 40)
		qx, _ := spot(game, unit, 500 - 45, 40)
		ex, _ := spot(game, unit, 500 + 45, 40)
		quarter := value(r)
		for nudge in ([]f64{0, -5, 5, -10, 10}) {
			call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"down"}},{{"type":"wait","frames":3}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":3}}]}}`, hx, hy + nudge, qx, hy + nudge))
			quarter = value(r)
			if quarter != 60 do break
			call(r, "input", `{"steps":[{"type":"up"},{"type":"wait","frames":2}]}`)
		}
		testing.expectf(t, abs(quarter - 25) <= 2, "dragged to a quarter along the track it is about 25: %v", quarter)
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":3}}]}}`, ex, hy))
		call(r, "screenshot", `{"target":"game","max_size":900}`)
		dragged := value(r)
		call(r, "input", `{"steps":[{"type":"up"},{"type":"wait","frames":3}]}`)
		testing.expectf(t, abs(dragged - 75) <= 2, "dragged to three quarters it is about 75: %v", dragged)
		// Hits by shape. Under the sprite mask a click lands only where the
		// heart shows the fill: the clear room beside its tip, a fifth of the
		// way in from the lower left corner, takes none. The picture sits
		// about 12 canvas units higher than `spot` says, so the clicks aim
		// that much lower.
		hx0, hy0 := spot(game, unit, 750 - 39, 380 - 51)
		click(r, hx0, hy0)
		frames(r, 4)
		testing.expect(t, !is_on(r, "Heart Fill"), "a click in the mask sprite's clear corner lands on nothing")
		hx1, hy1 := spot(game, unit, 750, 372)
		click(r, hx1, hy1)
		frames(r, 4)
		testing.expect(t, is_on(r, "Heart Fill"), "a click on the heart lands on what is under the mask")
		// An Image with an alpha threshold: the same, by its own sprite.
		ax0, ay0 := spot(game, unit, -672 - 19, -370 - 34)
		click(r, ax0, ay0)
		frames(r, 4)
		testing.expect(t, !is_on(r, "Alpha Image"), "a click in the image's clear corner misses it")
		ax1, ay1 := spot(game, unit, -672, -376)
		click(r, ax1, ay1)
		frames(r, 4)
		testing.expect(t, is_on(r, "Alpha Image"), "a click on its opaque part hits it")
		// The corner is inside the rect: with no threshold the same click hits.
		call(r, "set_property", `{"name":"Alpha Image","component":"Image","path":"alpha_hit_threshold","value":"0"}`)
		click(r, ax0, ay0)
		frames(r, 4)
		testing.expect(t, !is_on(r, "Alpha Image"), "with no threshold the corner is the image's too")
		// A finger on a touch screen: a tap on the third toggle turns it on.
		fx, fy := spot(game, unit, 556, -15)
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"touch","id":7,"phase":"down","x":%v,"y":%v}},{{"type":"wait","frames":3}},{{"type":"touch","id":7,"phase":"up","x":%v,"y":%v}},{{"type":"wait","frames":3}}]}}`, fx, fy, fx, fy))
		testing.expect(t, is_on(r, "Toggle 3") && !is_on(r, "Toggle 2"), "a finger's tap turns the third toggle on")
	}
	// The InputField and the Dropdown, beside the grid at canvas x 750: real
	// keys and typed text reach the field, and a click on a row of the open
	// list picks its option.
	if game_shown {
		unit := game[2] / 1800
		spot :: proc(game: [4]f64, unit, x, y: f64) -> (f64, f64) {
			return game.x + game[2] / 2 + x * unit, game.y + game[3] / 2 + 18 - y * unit
		}
		typed :: proc(r: ^Run) -> string {
			s, _ := at(call(r, "get_property", `{"name":"Input Field","component":"InputField","path":"text"}`), "value").(json.String)
			return string(s)
		}
		fx, fy := spot(game, unit, 750, 10)
		click(r, fx, fy)
		frames(r, 3)
		call(r, "input", `{"steps":[{"type":"text","text":"Hi there"},{"type":"wait","frames":3}]}`)
		testing.expectf(t, typed(r) == "Hi there", "typed text reaches the field: %q", typed(r))
		call(r, "screenshot", `{"target":"game","max_size":900}`)
		call(r, "input", `{"steps":[{"type":"key","name":"backspace"},{"type":"wait","frames":2},{"type":"key","name":"backspace","down":false},{"type":"wait","frames":2},{"type":"key","name":"left"},{"type":"wait","frames":2},{"type":"key","name":"left","down":false},{"type":"wait","frames":2},{"type":"text","text":"-"},{"type":"wait","frames":3}]}`)
		testing.expectf(t, typed(r) == "Hi the-r", "Backspace, the left arrow and a character edit it: %q", typed(r))
		call(r, "input", `{"steps":[{"type":"key","name":"return"},{"type":"wait","frames":2},{"type":"key","name":"return","down":false},{"type":"wait","frames":3},{"type":"text","text":"x"},{"type":"wait","frames":3}]}`)
		testing.expectf(t, typed(r) == "Hi the-r", "after Enter the field takes no more typing: %q", typed(r))

		value :: proc(r: ^Run) -> f64 {
			return as_f64(at(call(r, "get_property", `{"name":"Dropdown","component":"Dropdown","path":"value"}`), "value"))
		}
		dx, dy := spot(game, unit, 750, -150)
		testing.expectf(t, value(r) == 0, "the dropdown starts on its first option: %v", value(r))
		click(r, dx, dy)
		frames(r, 5)
		call(r, "screenshot", `{"target":"game","max_size":900}`)
		// The third row of the open list.
		rx, ry := spot(game, unit, 750, -248)
		click(r, rx, ry)
		frames(r, 5)
		testing.expectf(t, value(r) == 2, "a click on the third row picks it: %v", value(r))
		caption, _ := at(call(r, "get_property", `{"name":"Dropdown Label","component":"Text","path":"text"}`), "value").(json.String)
		testing.expectf(t, caption == "High", "the label shows the picked option: %q", caption)
		call(r, "screenshot", `{"target":"game","max_size":900}`)
	}
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 5)

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
