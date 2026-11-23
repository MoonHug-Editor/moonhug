package scenarios

// The Project window's rows: a file or a folder dragged onto a folder moves
// into it with its .meta, a right click selects a folder, the footer names
// the selected item, and a drag from empty space in the grid selects the
// cells it covers.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

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
