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
