package scenarios

// Pointer events in a real editor while the game plays: a card with the
// mhgui sample's UIDemoDrag script, which takes its events with
// @(comp_on_pointer_ui), follows a drag made with real mouse input in the
// Game window.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

// A camera, a canvas the pointer reaches, and a 300 x 200 Shape at its
// centre with the UIDemoDrag script.
@(private = "file")
_POINTER_SCENE :: `{"root":1,"next_local_id":100,"transforms":[{"local_id":1,"name":"Main","is_active":true,"position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1],"render_layer":1,"parent":{"pptr":{"local_id":0,"guid":"00000000-0000-0000-0000-000000000000"}},"children":[{"pptr":{"local_id":11,"guid":"00000000-0000-0000-0000-000000000000"}},{"pptr":{"local_id":13,"guid":"00000000-0000-0000-0000-000000000000"}}],"components":[]},{"local_id":11,"name":"Camera","is_active":true,"position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1],"render_layer":1,"parent":{"pptr":{"local_id":1,"guid":"00000000-0000-0000-0000-000000000000"}},"children":[],"components":[{"local_id":12}]},{"local_id":13,"name":"Canvas","is_active":true,"position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1],"render_layer":1,"parent":{"pptr":{"local_id":1,"guid":"00000000-0000-0000-0000-000000000000"}},"children":[{"pptr":{"local_id":16,"guid":"00000000-0000-0000-0000-000000000000"}}],"components":[{"local_id":14},{"local_id":15}]},{"local_id":16,"name":"Card","is_active":true,"position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1],"render_layer":1,"parent":{"pptr":{"local_id":13,"guid":"00000000-0000-0000-0000-000000000000"}},"children":[],"components":[{"local_id":17},{"local_id":18},{"local_id":19},{"local_id":20}]}],"nested_scenes":[],"breadcrumbs":[],"components":[{"__type":"7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d","base":{"enabled":true,"local_id":12},"clear_color":[0.06,0.06,0.09,1.0],"far_clip":1000.0,"fov":60.0,"near_clip":0.30000001,"order":0,"render_layer_mask":4294967295},{"__type":"ba2db3cd-79be-4d26-9cab-be3fc317d685","plane_distance":100.0,"render_camera":{"local_id":0},"render_mode":0,"sort_order":0,"base":{"enabled":true,"local_id":14}},{"__type":"b625f6b5-e1fd-4590-9757-ffa073e23bef","ignore_reversed_graphics":true,"base":{"enabled":true,"local_id":15}},{"__type":"36e133bb-7979-48ba-8b1b-57385558f37d","anchor_min":[0.5,0.5],"anchor_max":[0.5,0.5],"anchored_position":[0,0,0],"pivot":[0.5,0.5],"size_delta":[300,200],"z_index":0,"base":{"enabled":true,"local_id":17}},{"__type":"56334c3e-5a5d-4a74-981f-3682e7c9dc9a","base":{"enabled":true,"local_id":18}},{"__type":"4405f377-8e06-4b47-804a-f6ed73d030fd","graphic":{"color":[0.2,0.23,0.33,1],"material":{"guid":"00000000-0000-0000-0000-000000000000","local_id":0},"raycast_target":true},"kind":0,"corner_radius":[14,14,14,14],"border_width":2,"border_color":[0.45,0.5,0.65,1],"gradient":false,"gradient_color":[1,1,1,1],"gradient_angle":0,"shadow":{"color":[0,0,0,0.5],"offset":[0,-6],"blur":14,"spread":0},"inner_shadow":{"color":[0,0,0,0],"offset":[0,-2],"blur":4,"spread":0},"base":{"enabled":true,"local_id":19}},{"__type":"b7e7e442-92de-4e24-9804-82d9f8b9462d","border":[0.45,0.5,0.65,1.0],"border_hover":[1.0,0.85,0.3,1.0],"base":{"enabled":true,"local_id":20}}]}`

@(test)
ui_pointer_drags_a_card_in_play :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", _POINTER_SCENE)
	for file in ([]string{"white.png", "shaders/ui_shape.glsl", "materials/Shape.mat"}) {
		project_copy(r, fmt.tprintf("plugins/mhgui/assets/%s", file), fmt.tprintf("assets/%s", file))
		project_copy(r, fmt.tprintf("plugins/mhgui/assets/%s.meta", file), fmt.tprintf("assets/%s.meta", file))
	}
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Window/General/Game"}`)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 10)

	card_at :: proc(r: ^Run) -> [2]f64 {
		p, _ := at(call(r, "get_property", `{"name":"Card","component":"RectTransform","path":"anchored_position"}`), "value").(json.Array)
		if len(p) < 2 do return {}
		return {as_f64(p[0]), as_f64(p[1])}
	}
	game, shown := window_rect(r, "Game")
	if !testing.expect(t, shown, "the Game window is open") do return
	// The card sits at the canvas centre, the middle of the game picture.
	cx, cy := game.x + game[2] / 2, game.y + game[3] / 2 + 10
	testing.expectf(t, card_at(r) == {0, 0}, "the card starts at the centre: %v", card_at(r))

	// A click first, so the Game window has the keyboard and mouse focus.
	click(r, cx, cy)
	frames(r, 3)
	testing.expectf(t, card_at(r) == {0, 0}, "a click does not move it: %v", card_at(r))

	// A drag to the right and up.
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"down"}},{{"type":"wait","frames":2}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"up"}},{{"type":"wait","frames":3}}]}}`, cx, cy, cx + 30, cy - 10, cx + 60, cy - 20))
	moved := card_at(r)
	testing.expectf(t, moved.x > 20 && moved.y > 5, "the card followed the drag right and up: %v", moved)
	testing.expectf(t, abs(moved.x / moved.y - 3) < 0.3, "by the pointer's own movement, three across for one up: %v", moved)
	call(r, "screenshot", `{"target":"game","max_size":700}`)

	// Off the card, a drag moves nothing.
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"down"}},{{"type":"wait","frames":2}},{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"up"}},{{"type":"wait","frames":3}}]}}`, game.x + 30, game.y + game[3] - 30, game.x + 80, game.y + game[3] - 60))
	testing.expectf(t, card_at(r) == moved, "a drag that starts off the card leaves it: %v", card_at(r))

	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 5)
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
