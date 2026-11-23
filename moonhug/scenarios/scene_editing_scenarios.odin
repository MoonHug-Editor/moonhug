package scenarios

// Scene editing conveniences in a real editor: an object made from the Scene
// window's menu lands where the menu was opened, the Scale row's link keeps
// proportions, a locked object is passed over by a click, and the camera
// preferences open from their overlay.

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:time"

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
	// The lock sits in the gutter at the row's left end: its exact place
	// follows the font, so a few places are tried until the click after it
	// passes over.
	for inset in ([]f64{18, 14, 22}) {
		click(r, hier.x + inset, row.y + row[3] / 2)
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

// The arrow keys nudge the selection in a 2D view: a tap is one snap step
// along the screen's axis, Shift makes it ten, a hold repeats and is one
// undo step. In a perspective view the keys move nothing.
@(test)
scene_nudge :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)

	undo_top :: proc(r: ^Run) -> i64 { return as_int(at(call(r, "undo_history"), "top")) }
	tap :: proc(r: ^Run, key: string, shift := false) {
		if shift do call(r, "input", `{"steps":[{"type":"key","name":"shift"},{"type":"wait","frames":1}]}`)
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"key","name":%q}},{{"type":"wait","frames":1}},{{"type":"key","name":%q,"down":false}},{{"type":"wait","frames":3}}]}}`, key, key))
		if shift do call(r, "input", `{"steps":[{"type":"key","name":"shift","down":false},{"type":"wait","frames":1}]}`)
	}

	// The Scene window takes the keys once it is focused: its 2D button does both.
	two_d, has := item_rect(r, "Scene", "2D")
	if !testing.expect(t, has, "the 2D button") do return
	call(r, "select", `{"name":"Main"}`)

	// In perspective the arrows move nothing. A click on the button and one
	// back leaves the view in perspective, with the Scene window focused.
	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 3)
	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 3)
	tap(r, "right")
	pos, _, _ := _object(r, "Main")
	testing.expectf(t, pos == {0, 0, 0}, "in a perspective view an arrow key moves nothing: %v", pos)

	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 3)
	top := undo_top(r)
	tap(r, "right")
	pos, _, _ = _object(r, "Main")
	step := pos.x
	testing.expectf(t, step > 0 && pos.y == 0 && pos.z == 0, "Right moves one step along X: %v", pos)
	testing.expect_value(t, undo_top(r), top + 1)

	tap(r, "up", shift = true)
	pos, _, _ = _object(r, "Main")
	testing.expectf(t, abs(pos.y - step * 10) < 1e-4 && abs(pos.x - step) < 1e-6, "Shift+Up moves ten steps along Y: %v, step %v", pos, step)
	testing.expect_value(t, undo_top(r), top + 2)

	// A hold of over half a second repeats, and is one undo step.
	call(r, "input", `{"steps":[{"type":"key","name":"left"},{"type":"wait","frames":2}]}`)
	time.sleep(700 * time.Millisecond)
	call(r, "input", `{"steps":[{"type":"key","name":"left","down":false},{"type":"wait","frames":3}]}`)
	pos, _, _ = _object(r, "Main")
	testing.expectf(t, pos.x < step - step * 2.5, "a held Left repeats: x %v, step %v", pos.x, step)
	testing.expect_value(t, undo_top(r), top + 3)
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	pos, _, _ = _object(r, "Main")
	testing.expectf(t, abs(pos.x - step) < 1e-6, "one undo takes back the whole hold: x %v, step %v", pos.x, step)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}

// A change of an object's render layers asks whether its children take them
// too. Yes changes every object under it, in the same undo step.
@(test)
render_layers_to_children :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 4, "transforms": [
		{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [{"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}], "components": []},
		{"local_id": 2, "name": "Child", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [{"pptr": {"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}], "components": []},
		{"local_id": 3, "name": "Leaf", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}
	], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)

	layers :: proc(r: ^Run, name: string) -> i64 {
		return as_int(at(call(r, "get_property", fmt.tprintf(`{{"name":%q,"path":"render_layer"}}`, name)), "value"))
	}
	undo_top :: proc(r: ^Run) -> i64 { return as_int(at(call(r, "undo_history"), "top")) }
	// Opens the Render Layers list of the selected object and picks `item`.
	pick :: proc(r: ^Run, t: ^testing.T, item: string) -> bool {
		rows := _rects(r, "Inspector", "Render Layers")
		if !testing.expect(t, len(rows) > 0, "the Inspector has the Render Layers row") do return false
		// The rectangle is the row's label: its list is at the window's right.
		row := rows[len(rows) - 1]
		insp, _ := window_rect(r, "Inspector")
		click(r, insp.x + insp[2] - 60, row.y + row[3] / 2)
		frames(r, 3)
		entry, has := item_rect(r, "popup", item)
		if !testing.expectf(t, has, "the list has %q", item) do return false
		click(r, entry.x + 10, entry.y + entry[3] / 2)
		// The pick closes the list. Escape would answer the dialog, so no key here.
		frames(r, 4)
		return true
	}

	// The leaf has no children: its change asks nothing.
	call(r, "select", `{"name":"Leaf"}`)
	frames(r, 3)
	if !pick(r, t, "Nothing") do return
	testing.expect_value(t, layers(r, "Leaf"), 0)
	testing.expectf(t, !as_bool(at(call(r, "dialog"), "open")), "an object without children asks nothing")

	call(r, "select", `{"name":"Main"}`)
	frames(r, 3)
	top := undo_top(r)
	if !pick(r, t, "Everything") do return
	everything := layers(r, "Main")
	testing.expectf(t, everything != 1, "the row changed the object's layers: %v", everything)
	asked := call(r, "dialog")
	testing.expectf(t, as_bool(at(asked, "open")) && as_string(at(asked, "title")) == "Change Render Layers", "the change asks about the children: %v", asked)
	testing.expect_value(t, layers(r, "Child"), 1)
	call(r, "dialog", `{"press":"Yes, change children"}`)
	frames(r, 3)
	testing.expect_value(t, layers(r, "Child"), everything)
	testing.expect_value(t, layers(r, "Leaf"), everything)
	testing.expect_value(t, undo_top(r), top + 1)

	// One undo takes back the object's change and its children's.
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	testing.expect_value(t, layers(r, "Main"), 1)
	testing.expect_value(t, layers(r, "Child"), 1)
	testing.expect_value(t, layers(r, "Leaf"), 0)

	// No: the object alone changes.
	if !pick(r, t, "Nothing") do return
	testing.expectf(t, as_bool(at(call(r, "dialog"), "open")), "the next change asks again")
	call(r, "dialog", `{"press":"No, this object only"}`)
	frames(r, 3)
	testing.expect_value(t, layers(r, "Main"), 0)
	testing.expect_value(t, layers(r, "Child"), 1)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}

// The wheel zooms the Scene view toward the pointer: the point under it
// stays under it. An object made at a spot of the view before a zoom and one
// made at the same spot after it land on the same place.
@(test)
scene_zoom_goes_to_the_pointer :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	scene, shown := window_rect(r, "Scene")
	if !testing.expect(t, shown, "the Scene window is open") do return
	// 2D: the pointer's spot maps to one point of the XY plane.
	two_d, has := item_rect(r, "Scene", "2D")
	if !testing.expect(t, has, "the 2D button") do return
	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 3)

	// A spot well off the picture's centre.
	x, y := scene.x + scene[2] * 0.8, scene.y + scene[3] * 0.3
	make_at :: proc(r: ^Run, t: ^testing.T, x, y: f64, name: string) -> ([3]f64, bool) {
		_right_click(r, x, y)
		create, has_create := item_rect(r, "popup", "Create Empty")
		if !testing.expect(t, has_create, "the Scene window's menu offers Create Empty") do return {}, false
		click(r, create.x + create[2] / 2, create.y + create[3] / 2)
		frames(r, 4)
		call(r, "rename_object", fmt.tprintf(`{{"name":"Transform","new_name":%q}}`, name))
		frames(r, 2)
		pos, _, made := _object(r, name)
		return pos, made
	}
	before, ok := make_at(r, t, x, y, "Before")
	if !testing.expect(t, ok, "an object at the spot") do return
	testing.expectf(t, abs(before.x) > 0.5, "the spot is off the centre: %v", before)

	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"wheel","y":4}},{{"type":"wait","frames":4}}]}}`, x, y))
	zoomed_in, ok_in := make_at(r, t, x, y, "ZoomedIn")
	if !testing.expect(t, ok_in, "an object at the spot after zooming in") do return
	testing.expectf(t, abs(zoomed_in.x - before.x) < 0.02 && abs(zoomed_in.y - before.y) < 0.02, "zoomed in, the spot is still the same point: %v, was %v", zoomed_in, before)

	// The view did zoom: the picture's centre shows another point than the
	// one it would without the zoom going to the pointer, and a spot beside
	// the pointer is nearer to it than before.
	near_before_x := x - 100
	beside, ok_beside := make_at(r, t, near_before_x, y, "Beside")
	if !testing.expect(t, ok_beside) do return
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"wheel","y":-7}},{{"type":"wait","frames":4}}]}}`, x, y))
	zoomed_out, ok_out := make_at(r, t, x, y, "ZoomedOut")
	if !testing.expect(t, ok_out, "an object at the spot after zooming out") do return
	testing.expectf(t, abs(zoomed_out.x - before.x) < 0.05 && abs(zoomed_out.y - before.y) < 0.05, "zoomed out, the spot is still the same point: %v, was %v", zoomed_out, before)
	far, ok_far := make_at(r, t, near_before_x, y, "BesideFar")
	if !testing.expect(t, ok_far) do return
	testing.expectf(t, abs(far.x - before.x) > abs(beside.x - before.x) * 1.5, "100 points beside the pointer is further away after zooming out: %v then %v, the spot %v", beside, far, before)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}

// The points of a UiPolygon are handles in the Scene window, with the
// Handles tool: a drag moves a point, and a drag from the middle of an edge
// adds one. Each is one undo step.
@(test)
ui_polygon_points_drag_in_the_scene :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	project_copy(r, "plugins/mhgui/assets/white.png", "assets/white.png")
	project_copy(r, "plugins/mhgui/assets/white.png.meta", "assets/white.png.meta")
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	scene, shown := window_rect(r, "Scene")
	if !testing.expect(t, shown, "the Scene window is open") do return
	two_d, has := item_rect(r, "Scene", "2D")
	if !testing.expect(t, has, "the 2D button") do return
	click(r, two_d.x + two_d[2] / 2, two_d.y + two_d[3] / 2)
	frames(r, 3)

	// A 200 x 150 polygon whose rect spans canvas x 200 to 400 and y 125 to
	// 275. In the Scene window a canvas unit is a world unit from the origin.
	call(r, "invoke_menu", `{"path":"GameObject/UI/Polygon"}`)
	frames(r, 3)
	set :: proc(r: ^Run, path, value: string) {
		call(r, "set_property", fmt.tprintf(`{{"name":"Polygon","component":"RectTransform","path":%q,"value":%q}}`, path, value))
	}
	set(r, "anchor_min", "[0, 0]")
	set(r, "anchor_max", "[0, 0]")
	set(r, "anchored_position", "[300, 200, 0]")
	set(r, "size_delta", "[200, 150]")
	frames(r, 2)
	call(r, "run_command", `{"command":"Edit/Frame Selected"}`)
	frames(r, 20)

	// Where a world point is in the window: two objects made at known spots
	// of the window say how the view maps.
	ax, ay := scene.x + scene[2] * 0.2, scene.y + scene[3] * 0.25
	bx, by := scene.x + scene[2] * 0.8, scene.y + scene[3] * 0.75
	made_at :: proc(r: ^Run, t: ^testing.T, x, y: f64, name: string) -> ([3]f64, bool) {
		_right_click(r, x, y)
		create, has_create := item_rect(r, "popup", "Create Empty")
		if !testing.expect(t, has_create, "the Scene window's menu offers Create Empty") do return {}, false
		click(r, create.x + create[2] / 2, create.y + create[3] / 2)
		frames(r, 4)
		call(r, "rename_object", fmt.tprintf(`{{"name":"Transform","new_name":%q}}`, name))
		frames(r, 2)
		pos, _, made := _object(r, name)
		return pos, made
	}
	a, a_ok := made_at(r, t, ax, ay, "A")
	b, b_ok := made_at(r, t, bx, by, "B")
	if !testing.expect(t, a_ok && b_ok && a.x != b.x && a.y != b.y, "two objects to map the view by") do return
	View :: struct {
		ax, ay, bx, by: f64,
		a, b:           [3]f64,
	}
	view := View{ax, ay, bx, by, a, b}
	screen :: proc(v: View, wx, wy: f64) -> (f64, f64) {
		return v.ax + (wx - v.a.x) / (v.b.x - v.a.x) * (v.bx - v.ax), v.ay + (wy - v.a.y) / (v.b.y - v.a.y) * (v.by - v.ay)
	}
	points :: proc(r: ^Run) -> [][2]f64 {
		list, _ := at(call(r, "get_property", `{"name":"Polygon","component":"UiPolygon","path":"points"}`), "value").(json.Array)
		out := make([dynamic][2]f64, context.temp_allocator)
		for p in list {
			xy, _ := p.(json.Array)
			if len(xy) == 2 do append(&out, [2]f64{as_f64(xy[0]), as_f64(xy[1])})
		}
		return out[:]
	}

	call(r, "select", `{"name":"Polygon"}`)
	call(r, "run_command", `{"command":"Scene/Handles Tool"}`)
	frames(r, 4)
	before := points(r)
	if !testing.expectf(t, len(before) == 7, "the menu's arrow has seven points: %v", before) do return

	// The arrow's tip, point 3 at (1, 0.5) of the rect: world (400, 200).
	// Dragged 50 right and 30 up it is (1.25, 0.7) of the rect.
	x0, y0 := screen(view, 400, 200)
	x1, y1 := screen(view, 450, 230)
	drag_mouse(r, x0, y0, x1, y1)
	frames(r, 3)
	moved := points(r)
	if testing.expectf(t, len(moved) == 7, "a drag on a point adds none: %v", moved) {
		testing.expectf(t, abs(moved[3].x - 1.25) < 0.03 && abs(moved[3].y - 0.7) < 0.03, "the tip followed the drag: %v", moved[3])
		testing.expectf(t, moved[2] == before[2] && moved[4] == before[4], "its neighbours stayed: %v %v", moved[2], moved[4])
	}
	call(r, "screenshot", `{"target":"scene","max_size":900}`)

	// The middle of the first edge, (0.3, 0.3) of the rect: world (260, 170).
	// A drag from it adds a point there and takes it 30 down: (0.3, 0.1).
	x0, y0 = screen(view, 260, 170)
	x1, y1 = screen(view, 260, 140)
	drag_mouse(r, x0, y0, x1, y1)
	frames(r, 3)
	added := points(r)
	if testing.expectf(t, len(added) == 8, "a drag from an edge's middle adds a point: %v", added) {
		testing.expectf(t, abs(added[1].x - 0.3) < 0.03 && abs(added[1].y - 0.1) < 0.03, "the new point is where it was dragged to: %v", added[1])
	}
	call(r, "screenshot", `{"target":"scene","max_size":900}`)

	// One undo for the added point, one more for the moved one.
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	testing.expectf(t, len(points(r)) == 7, "undo takes the added point away: %v", points(r))
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	back := points(r)
	testing.expectf(t, len(back) == 7 && back[3] == before[3], "and then puts the tip back: %v", back)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
