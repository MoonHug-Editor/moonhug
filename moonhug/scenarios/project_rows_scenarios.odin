package scenarios

// The Project window's rows: a file or a folder dragged onto a folder moves
// into it with its .meta, a right click selects a folder, the footer names
// the selected item, and a drag from empty space in the grid selects the
// cells it covers.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
_ZERO :: `{"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}`

@(private = "file")
_scene :: proc(root: string) -> string {
	return fmt.tprintf(`{{"root": 1, "next_local_id": 2, "transforms": [{{"local_id": 1, "name": %q, "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": %s, "children": [], "components": []}}], "nested_scenes": [], "breadcrumbs": [], "components": []}}`, root, _ZERO)
}

@(private = "file")
_ROCK_GUID :: "5ce4e000-0000-4000-8000-0000000000d1"

// Every rectangle item_rect finds for `label` in the Project window, in draw
// order: the tree's row before the list's.
@(private = "file")
_rects :: proc(r: ^Run, label: string) -> [][4]f64 {
	res, code, _ := call_raw(r, "item_rect", fmt.tprintf(`{{"window":"Project","label":%q}}`, label))
	if code != "" do return nil
	matches, is_list := at(res, "matches").(json.Array)
	if !is_list do return nil
	out := make([dynamic][4]f64, context.temp_allocator)
	for m in matches do append(&out, [4]f64{as_f64(at(m, "x")), as_f64(at(m, "y")), as_f64(at(m, "width")), as_f64(at(m, "height"))})
	return out[:]
}

@(private = "file")
_guid_of :: proc(r: ^Run, meta: string) -> string {
	return as_string(at(project_json(r, meta), "guid"))
}

@(test)
project_rows_move_by_drag_and_select :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Rock.scene", _scene("Rock"))
	project_write(r, "assets/Rock.scene.meta", `{"guid": "` + _ROCK_GUID + `"}`)
	project_write(r, "assets/Stone.scene", _scene("Stone"))
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	project_write(r, "assets/Box/Lid.scene", _scene("Lid"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Rock.scene"}`)
	frames(r, 5)

	rock := _rects(r, "Rock.scene")
	art := _rects(r, "Art")
	if !testing.expectf(t, len(rock) == 1 && len(art) == 2, "Rock.scene is listed, Art is in the tree and in the list: %v, %v", rock, art) do return

	// Rock.scene onto Art in the tree: the drag says what the drop does, and
	// on release the file and its .meta are in Art.
	drag_mouse(r, rock[0].x + 10, rock[0].y + rock[0][3] / 2, art[0].x + 10, art[0].y + art[0][3] / 2, release = false)
	_, says := item_rect(r, "tooltip", "Move Rock.scene to Art")
	testing.expect(t, says, "the drag's tooltip says the file moves to Art")
	testing.expect(t, os.exists(project_path(r, "assets/Rock.scene")), "hovering moves nothing")
	call(r, "input", `{"steps":[{"type":"up"},{"type":"wait","frames":5}]}`)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Rock.scene")) && !os.exists(project_path(r, "assets/Rock.scene")), "Rock.scene is in Art")
	testing.expect(t, !os.exists(project_path(r, "assets/Rock.scene.meta")), "its .meta left with it")
	testing.expectf(t, _guid_of(r, "assets/Art/Rock.scene.meta") == _ROCK_GUID, "and it keeps its id: %v", _guid_of(r, "assets/Art/Rock.scene.meta"))

	// The list shows Art now, where the moved file is selected. Back to the
	// root: Stone.scene onto the list's Art row, the folder Box onto the
	// tree's.
	roots := _rects(r, "assets")
	if !testing.expect(t, len(roots) > 0, "the tree shows the assets root") do return
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	stone := _rects(r, "Stone.scene")
	art = _rects(r, "Art")
	if !testing.expectf(t, len(stone) == 1 && len(art) == 2, "the root lists Stone.scene and Art again: %v, %v", stone, art) do return
	drag_mouse(r, stone[0].x + 10, stone[0].y + stone[0][3] / 2, art[1].x + 10, art[1].y + art[1][3] / 2)
	frames(r, 3)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Stone.scene")), "Stone.scene moved onto the list's Art row")

	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	box := _rects(r, "Box")
	art = _rects(r, "Art")
	if !testing.expectf(t, len(box) == 2 && len(art) == 2, "the root lists the folders Box and Art: %v, %v", box, art) do return
	drag_mouse(r, box[1].x + 10, box[1].y + box[1][3] / 2, art[0].x + 10, art[0].y + art[0][3] / 2)
	frames(r, 3)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Box/Lid.scene")) && !os.exists(project_path(r, "assets/Box")), "the folder Box moved into Art with what it holds")

	// A right click on a folder's row selects it, and the footer names it.
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	art = _rects(r, "Art")
	if !testing.expect(t, len(art) == 2, "Art is still in the tree and the list") do return
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"up","button":"right"}},{{"type":"wait","frames":3}},{{"type":"key","name":"Escape"}},{{"type":"key","name":"Escape","down":false}},{{"type":"wait","frames":3}}]}}`, art[1].x + 10, art[1].y + art[1][3] / 2))
	_, named := item_rect(r, "Project", "assets/Art")
	testing.expect(t, named, "the footer shows the right-clicked folder's path")

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

@(test)
project_grid_band_selects_cells :: proc(t: ^testing.T) {
	r := begin(t)
	for name in ([]string{"A", "B", "C"}) do project_write(r, fmt.tprintf("assets/%s.scene", name), _scene(name))
	editor_start(r)
	call(r, "editor_setting", `{"name":"project_zoom","value":"0.5"}`)
	call(r, "ping_asset", `{"path":"assets/A.scene"}`)
	frames(r, 8)

	a := _rects(r, "A.scene")
	c := _rects(r, "C.scene")
	if !testing.expectf(t, len(a) == 1 && len(c) == 1, "the grid shows the three files: %v, %v", a, c) do return
	testing.expectf(t, abs(a[0].y - c[0].y) < 4 && c[0].x > a[0].x + 40, "as cells side by side: %v, %v", a[0], c[0])

	// From empty space under the cells, up over A and B.
	b := _rects(r, "B.scene")
	if !testing.expect(t, len(b) == 1, "B.scene has its cell") do return
	drag_mouse(r, b[0].x + b[0][2] + 4, a[0].y + 40, a[0].x + 2, a[0].y - 30)
	frames(r, 3)
	_, two := item_rect(r, "Project", "2 selected")
	testing.expect(t, two, "the band selected the two cells it covered")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

@(private = "file")
_chord :: proc(r: ^Run, key: string) {
	mod := "cmd" when ODIN_OS == .Darwin else "ctrl"
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"key","name":%q}},{{"type":"key","name":%q}},{{"type":"key","name":%q,"down":false}},{{"type":"key","name":%q,"down":false}},{{"type":"wait","frames":4}}]}}`, mod, key, key, mod))
}

// A drop on a folder of the path bar, a tree folder that opens under a
// resting drag, and the question a taken name asks.
@(test)
project_rows_path_bar_auto_open_and_name_clash :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Rock.scene", _scene("Rock"))
	project_write(r, "assets/Rock.scene.meta", `{"guid": "` + _ROCK_GUID + `"}`)
	project_write(r, "assets/Stone.scene", _scene("Stone"))
	project_write(r, "assets/Art/Rock.scene", _scene("OldRock"))
	project_write(r, "assets/Art/Stone.scene", _scene("OldStone"))
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	project_write(r, "assets/Art/Up.scene", _scene("Up"))
	project_write(r, "assets/Art/Deep/Far.scene", _scene("Far"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Art/Inside.scene"}`)
	frames(r, 5)

	// Up.scene onto "assets" in the path bar: it moves to the root.
	up := _rects(r, "Up.scene")
	roots := _rects(r, "assets")
	if !testing.expectf(t, len(up) == 1 && len(roots) == 2, "Art lists Up.scene, and assets is in the tree and in the path bar: %v, %v", up, roots) do return
	drag_mouse(r, up[0].x + 10, up[0].y + up[0][3] / 2, roots[1].x + 6, roots[1].y + roots[1][3] / 2)
	frames(r, 3)
	testing.expect(t, os.exists(project_path(r, "assets/Up.scene")) && !os.exists(project_path(r, "assets/Art/Up.scene")), "Up.scene moved to the folder named in the path bar")

	// The list shows the root now. Back in Art: a drag resting on the
	// tree's folded Art opens it, and the drop lands on Deep, inside it.
	call(r, "ping_asset", `{"path":"assets/Art/Inside.scene"}`)
	frames(r, 5)
	inside := _rects(r, "Inside.scene")
	art := _rects(r, "Art")
	if !testing.expectf(t, len(inside) == 1 && len(art) >= 1, "Art lists Inside.scene, and the tree shows Art: %v, %v", inside, art) do return
	testing.expectf(t, len(_rects(r, "Deep")) == 1, "Deep is in the list only, the tree's Art is folded: %v", _rects(r, "Deep"))
	drag_mouse(r, inside[0].x + 10, inside[0].y + inside[0][3] / 2, art[0].x + 10, art[0].y + art[0][3] / 2, release = false)
	deep: [][4]f64
	for _ in 0 ..< 40 {
		time.sleep(50 * time.Millisecond)
		frames(r, 2)
		if deep = _rects(r, "Deep"); len(deep) == 2 do break
	}
	if !testing.expectf(t, len(deep) == 2, "the drag resting on Art opens it in the tree: %v", deep) {
		call(r, "input", `{"steps":[{"type":"up"}]}`)
		return
	}
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":3}},{{"type":"up"}},{{"type":"wait","frames":5}}]}}`, deep[0].x + 10, deep[0].y + deep[0][3] / 2))
	testing.expect(t, os.exists(project_path(r, "assets/Art/Deep/Inside.scene")), "Inside.scene landed in Deep")

	// Rock.scene onto Art, which has one: the editor asks. Keep Both gives
	// the new one another name.
	roots = _rects(r, "assets")
	if !testing.expect(t, len(roots) > 0, "the tree shows the assets root") do return
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	rock := _rects(r, "Rock.scene")
	art = _rects(r, "Art")
	if !testing.expectf(t, len(rock) == 1 && len(art) == 2, "the root lists Rock.scene and Art: %v, %v", rock, art) do return
	drag_mouse(r, rock[0].x + 10, rock[0].y + rock[0][3] / 2, art[1].x + 10, art[1].y + art[1][3] / 2)
	frames(r, 3)
	asked := call(r, "dialog")
	testing.expectf(t, as_bool(at(asked, "open")) && as_string(at(asked, "title")) == "Art already has Rock.scene", "the move asks about the taken name: %v", asked)
	testing.expect(t, os.exists(project_path(r, "assets/Rock.scene")), "nothing moved before the answer")
	call(r, "dialog", `{"press":"Keep Both"}`)
	frames(r, 5)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Rock 1.scene")) && os.exists(project_path(r, "assets/Art/Rock.scene")) && !os.exists(project_path(r, "assets/Rock.scene")), "Keep Both: the moved file has another name beside the one that was there")
	testing.expectf(t, _guid_of(r, "assets/Art/Rock 1.scene.meta") == _ROCK_GUID, "and keeps its id: %v", _guid_of(r, "assets/Art/Rock 1.scene.meta"))

	// Stone.scene the same way, answered with Skip: both stay.
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	stone := _rects(r, "Stone.scene")
	art = _rects(r, "Art")
	if !testing.expectf(t, len(stone) == 1 && len(art) == 2, "the root lists Stone.scene and Art: %v, %v", stone, art) do return
	drag_mouse(r, stone[0].x + 10, stone[0].y + stone[0][3] / 2, art[1].x + 10, art[1].y + art[1][3] / 2)
	frames(r, 3)
	call(r, "dialog", `{"press":"Skip"}`)
	frames(r, 5)
	testing.expect(t, os.exists(project_path(r, "assets/Stone.scene")) && os.exists(project_path(r, "assets/Art/Stone.scene")), "Skip leaves both where they are")

	// The keys: Duplicate copies the selected file beside it, Copy and Paste
	// the same.
	stone = _rects(r, "Stone.scene")
	if !testing.expect(t, len(stone) == 1, "Stone.scene is still listed") do return
	click(r, stone[0].x + 10, stone[0].y + stone[0][3] / 2)
	_chord(r, "D")
	testing.expect(t, os.exists(project_path(r, "assets/Stone 1.scene")), "Duplicate on its key copies the selected file")
	stone = _rects(r, "Stone.scene")
	if !testing.expect(t, len(stone) == 1, "Stone.scene is still listed after the copy") do return
	click(r, stone[0].x + 10, stone[0].y + stone[0][3] / 2)
	_chord(r, "C")
	_chord(r, "V")
	testing.expect(t, os.exists(project_path(r, "assets/Stone 2.scene")), "Copy and Paste on their keys copy it again")

	// A right click on a file: the menu starts with the Edit band, and
	// Delete on its key asks about the selected file.
	stone = _rects(r, "Stone.scene")
	if !testing.expect(t, len(stone) == 1, "Stone.scene is still listed after the paste") do return
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"wait","frames":2}},{{"type":"up","button":"right"}},{{"type":"wait","frames":6}}]}}`, stone[0].x + 10, stone[0].y + stone[0][3] / 2))
	_, has_cut := item_rect(r, "popup", "Cut")
	_, has_reveal := item_rect(r, "popup", "Copy Path")
	testing.expect(t, has_cut && has_reveal, "the file's menu shows Cut and the Assets items")
	call(r, "input", `{"steps":[{"type":"key","name":"Escape"},{"type":"key","name":"Escape","down":false},{"type":"wait","frames":3}]}`)
	mod := "cmd" when ODIN_OS == .Darwin else "ctrl"
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"key","name":%q}},{{"type":"key","name":"Backspace"}},{{"type":"key","name":"Backspace","down":false}},{{"type":"key","name":%q,"down":false}},{{"type":"wait","frames":4}}]}}`, mod, mod))
	asked = call(r, "dialog")
	testing.expectf(t, as_bool(at(asked, "open")) && as_string(at(asked, "title")) == "Delete selected asset?", "Delete on its key asks about the file: %v", asked)
	call(r, "dialog", `{"press":"Cancel"}`)
	frames(r, 3)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// Near the list's bottom edge a drag scrolls the rows.
@(test)
project_rows_scroll_under_a_drag :: proc(t: ^testing.T) {
	r := begin(t)
	for i in 0 ..< 60 do project_write(r, fmt.tprintf("assets/Many/F%02d.scene", i), _scene("F"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Many/F00.scene"}`)
	frames(r, 5)

	first := _rects(r, "F01.scene")
	if !testing.expectf(t, len(first) == 1, "the folder's first rows are listed: %v", first) do return
	testing.expect(t, len(_rects(r, "F59.scene")) == 0, "its last row is below the pane, not drawn")
	window, shown := window_rect(r, "Project")
	if !testing.expect(t, shown, "the Project window is open") do return
	// The rows end above the footer's slider: a point just over it.
	drag_mouse(r, first[0].x + 10, first[0].y + first[0][3] / 2, first[0].x + 10, window.y + window[3] - 44, release = false)
	reached := false
	for _ in 0 ..< 80 {
		time.sleep(50 * time.Millisecond)
		frames(r, 2)
		if len(_rects(r, "F59.scene")) == 1 {
			reached = true
			break
		}
	}
	call(r, "input", `{"steps":[{"type":"up"},{"type":"wait","frames":3}]}`)
	testing.expect(t, reached, "the drag held near the bottom edge scrolled to the last row")
	testing.expect(t, os.exists(project_path(r, "assets/Many/F01.scene")), "and the release over a file of the same folder moved nothing")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
