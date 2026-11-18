package scenarios

// Scene editing conveniences in a real editor: an object made from the Scene
// window's menu lands where the menu was opened, the Scale row's link keeps
// proportions, a locked object is passed over by a click, and the camera
// preferences open from their overlay.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

@(private = "file")
_object :: proc(r: ^Run, name: string) -> (pos, scale: [3]f64, ok: bool) {
	list, _ := at(call(r, "list_objects", fmt.tprintf(`{{"name":%q,"detail":true}}`, name)), "objects").(json.Array)
	if len(list) != 1 do return
	p, _ := at(list[0], "position").(json.Array)
	if len(p) != 3 do return
	pos = {as_f64(p[0]), as_f64(p[1]), as_f64(p[2])}
	res, code, _ := call_raw(r, "get_property", fmt.tprintf(`{{"name":%q,"path":"scale"}}`, name))
	_ = code
	s, _ := at(res, "value").(json.Array)
	if len(s) == 3 do scale = {as_f64(s[0]), as_f64(s[1]), as_f64(s[2])}
	return pos, scale, true
}

@(private = "file")
_selection :: proc(r: ^Run) -> string {
	return fmt.tprint(at(call(r, "editor_state"), "selection"))
}

@(private = "file")
_right_click :: proc(r: ^Run, x, y: f64) {
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"up","button":"right"}},{{"type":"wait","frames":3}}]}}`, x, y))
}

// Every rectangle item_rect finds for `label` in `window`.
@(private = "file")
_rects :: proc(r: ^Run, window, label: string) -> [][4]f64 {
	res, code, _ := call_raw(r, "item_rect", fmt.tprintf(`{{"window":%q,"label":%q}}`, window, label))
	out := make([dynamic][4]f64, context.temp_allocator)
	if code != "" do return out[:]
	matches, _ := at(res, "matches").(json.Array)
	for m in matches do append(&out, [4]f64{as_f64(at(m, "x")), as_f64(at(m, "y")), as_f64(at(m, "width")), as_f64(at(m, "height"))})
	return out[:]
}

@(test)
scene_editing_conveniences :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	project_copy(r, "plugins/mhgui/assets/white.png", "assets/white.png")
	project_copy(r, "plugins/mhgui/assets/white.png.meta", "assets/white.png.meta")
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	scene, shown := window_rect(r, "Scene")
	if !testing.expect(t, shown, "the Scene window is open") do return
	cx, cy := scene.x + scene[2] * 0.5, scene.y + scene[3] * 0.5

	// An object made from the Scene window's menu lands where it was opened:
	// over empty space, on the grid plane, away from the origin.
	_right_click(r, cx + 140, cy + 90)
	create, has_create := item_rect(r, "popup", "Create Empty")
	if !testing.expect(t, has_create, "the Scene window's menu offers Create Empty") do return
	click(r, create.x + create[2] / 2, create.y + create[3] / 2)
	frames(r, 4)
	pos, _, made := _object(r, "Transform")
	if !testing.expect(t, made, "the menu made an object") do return
	testing.expectf(t, abs(pos.y) < 0.001 && abs(pos.x) + abs(pos.z) > 0.5, "it is on the grid plane where the menu opened, not at the origin: %v", pos)

	// The Scale row's link: with it on, a drag on X scales Y and Z too.
	link := _rects(r, "Inspector", "\ue250")
	if !testing.expectf(t, len(link) > 0, "the Scale row has its link button") do return
	click(r, link[0].x + link[0][2] / 2, link[0].y + link[0][3] / 2)
	frames(r, 2)
	// The X field is the first one right of the link button.
	fx, fy := link[0].x + link[0][2] + 40, link[0].y + link[0][3] / 2
	drag_mouse(r, fx, fy, fx + 60, fy)
	call(r, "screenshot", `{"target":"window","window":"Inspector","max_size":700}`)
	frames(r, 3)
	_, scale, _ := _object(r, "Transform")
	testing.expectf(t, scale.x != 1 && abs(scale.x - scale.y) < 0.001 && abs(scale.x - scale.z) < 0.001, "the three axes scaled together: %v", scale)

	// A locked object is passed over by a click in the Scene window.
	call(r, "invoke_menu", `{"path":"GameObject/UI/Image"}`)
	frames(r, 4)
	call(r, "invoke_menu", `{"path":"Edit/Frame Selected"}`)
	frames(r, 30)
	image_selected := _selection(r)
	call(r, "input", `{"steps":[{"type":"key","name":"Escape"},{"type":"key","name":"Escape","down":false},{"type":"wait","frames":2}]}`)
	click(r, cx, cy)
	frames(r, 3)
	testing.expectf(t, _selection(r) == image_selected, "unlocked, a click on the image selects it: %v, wanted %v", _selection(r), image_selected)

	row, has_row := item_rect(r, "Hierarchy", "Image")
	hier, _ := window_rect(r, "Hierarchy")
	if !testing.expect(t, has_row, "the Hierarchy lists the image") do return
	locked := false
	// The lock sits near the row's right end: its exact place follows the
	// font, so a few places are tried until the click after it passes over.
	for inset in ([]f64{44, 36, 52}) {
		click(r, hier.x + hier[2] - inset, row.y + row[3] / 2)
		frames(r, 2)
		call(r, "select", `{"name":"Main"}`)
		frames(r, 2)
		before := _selection(r)
		click(r, cx, cy)
		frames(r, 3)
		if _selection(r) != image_selected {
			locked = true
			_ = before
			break
		}
	}
	testing.expect(t, locked, "locked in the Hierarchy, a click on the image does not select it")
	call(r, "screenshot", `{"target":"window","window":"Hierarchy","max_size":500}`)

	// The camera preferences open from their overlay button.
	cam := _rects(r, "Scene", "\ue04b")
	if testing.expect(t, len(cam) > 0, "the Scene window has the camera overlay button") {
		click(r, cam[0].x + cam[0][2] / 2, cam[0].y + cam[0][3] / 2)
		frames(r, 3)
		for label in ([]string{"Field of view", "Fly speed", "Look sensitivity"}) {
			_, has := item_rect(r, "popup", label)
			testing.expectf(t, has, "the camera popup has %q", label)
		}
		call(r, "input", `{"steps":[{"type":"key","name":"Escape"},{"type":"key","name":"Escape","down":false},{"type":"wait","frames":2}]}`)
	}

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
