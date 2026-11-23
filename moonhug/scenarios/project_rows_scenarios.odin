package scenarios

// The Project window's rows: a file or a folder dragged onto a folder moves
// into it with its .meta, a right click selects a folder, the footer names
// the selected item, and a drag from empty space in the grid selects the
// cells it covers.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
	for m in matches {
		// The label is a part of the text found: "Art" is in the footer's
		// "assets/Art" too. A row's text is its name, after its glyph when
		// the glyph is drawn with it. The path bar is one text: its first
		// folder starts it.
		text := as_string(at(m, "label"))
		if text != label && !strings.has_suffix(text, fmt.tprintf("  %s", label)) && !strings.has_prefix(text, fmt.tprintf("%s ", label)) do continue
		append(&out, [4]f64{as_f64(at(m, "x")), as_f64(at(m, "y")), as_f64(at(m, "width")), as_f64(at(m, "height"))})
	}
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

// Files dragged in from the OS file browser are copied into the folder under
// the pointer, or into the folder the list shows.
@(test)
project_takes_files_dropped_from_the_os :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Keep.scene", _scene("Keep"))
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	// Outside the assets folder: files of the disk, not of the project.
	project_write(r, "outside/New.scene", _scene("New"))
	project_write(r, "outside/Other.scene", _scene("Other"))
	project_write(r, "outside/Pack/Deep.scene", _scene("Deep"))
	abs :: proc(r: ^Run, rel: string) -> string {
		path, _ := filepath.abs(project_path(r, rel), context.temp_allocator)
		return path
	}
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Keep.scene"}`)
	frames(r, 5)

	art := _rects(r, "Art")
	keep := _rects(r, "Keep.scene")
	if !testing.expectf(t, len(art) == 2 && len(keep) == 1, "the root lists Art and Keep.scene: %v, %v", art, keep) do return
	drop :: proc(r: ^Run, x, y: f64, files: ..string) {
		list := strings.builder_make(context.temp_allocator)
		for f, i in files do fmt.sbprintf(&list, "%s%q", "," if i > 0 else "", f)
		// The drag rests on the place for a few frames, then lets go.
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"drop","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"drop","x":%v,"y":%v}},{{"type":"wait","frames":2}},{{"type":"drop","x":%v,"y":%v,"files":[%s]}},{{"type":"wait","frames":5}}]}}`, x, y, x, y, x, y, strings.to_string(list)))
	}

	// A file and a folder onto the list's Art row: copies of both in Art,
	// the sources where they were.
	drop(r, art[1].x + 10, art[1].y + art[1][3] / 2, abs(r, "outside/New.scene"), abs(r, "outside/Pack"))
	testing.expect(t, os.exists(project_path(r, "assets/Art/New.scene")) && os.exists(project_path(r, "assets/Art/Pack/Deep.scene")), "the dropped file and folder are copied into Art")
	testing.expect(t, os.exists(project_path(r, "outside/New.scene")), "the source stays where it was")
	testing.expect(t, os.exists(project_path(r, "assets/Art/New.scene.meta")), "the copy is an asset with an id of its own")

	// Onto the tree's Art row, where the name is taken now: the editor asks.
	roots := _rects(r, "assets")
	if !testing.expect(t, len(roots) > 0, "the tree shows the assets root") do return
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	art = _rects(r, "Art")
	if !testing.expectf(t, len(art) == 2, "Art is in the tree and the list: %v", art) do return
	drop(r, art[0].x + 10, art[0].y + art[0][3] / 2, abs(r, "outside/New.scene"))
	asked := call(r, "dialog")
	testing.expectf(t, as_bool(at(asked, "open")) && as_string(at(asked, "title")) == "Art already has New.scene", "a taken name is asked about: %v", asked)
	call(r, "dialog", `{"press":"Skip"}`)
	frames(r, 3)
	testing.expect(t, !os.exists(project_path(r, "assets/Art/New 1.scene")), "Skip copies nothing")

	// Onto the list's empty space, under its rows: the folder it shows.
	window, shown := window_rect(r, "Project")
	keep = _rects(r, "Keep.scene")
	if !testing.expect(t, shown && len(keep) == 1, "the list shows the root") do return
	drop(r, keep[0].x + 40, window.y + window[3] - 70, abs(r, "outside/Other.scene"))
	testing.expect(t, os.exists(project_path(r, "assets/Other.scene")), "a drop on the list's empty space copies into the folder it shows")

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// A move by drag and a rename are undo steps: the file goes back with its
// .meta, and comes again on redo.
@(test)
project_moves_and_renames_undo :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Rock.scene", _scene("Rock"))
	project_write(r, "assets/Rock.scene.meta", `{"guid": "` + _ROCK_GUID + `"}`)
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Rock.scene"}`)
	frames(r, 5)

	rock := _rects(r, "Rock.scene")
	art := _rects(r, "Art")
	if !testing.expectf(t, len(rock) == 1 && len(art) == 2, "the root lists Rock.scene and Art: %v, %v", rock, art) do return
	drag_mouse(r, rock[0].x + 10, rock[0].y + rock[0][3] / 2, art[1].x + 10, art[1].y + art[1][3] / 2)
	frames(r, 3)
	if !testing.expect(t, os.exists(project_path(r, "assets/Art/Rock.scene")), "Rock.scene moved into Art") do return

	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 4)
	testing.expect(t, os.exists(project_path(r, "assets/Rock.scene")) && !os.exists(project_path(r, "assets/Art/Rock.scene")), "undo puts Rock.scene back")
	testing.expectf(t, _guid_of(r, "assets/Rock.scene.meta") == _ROCK_GUID, "with its .meta and its id: %v", _guid_of(r, "assets/Rock.scene.meta"))
	call(r, "invoke_menu", `{"path":"Edit/Redo"}`)
	frames(r, 4)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Rock.scene")) && !os.exists(project_path(r, "assets/Rock.scene")), "redo moves it again")
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 4)

	// A rename: the new name, then the old one back.
	rock = _rects(r, "Rock.scene")
	if !testing.expectf(t, len(rock) == 1, "Rock.scene is listed in the root again: %v", rock) do return
	click(r, rock[0].x + 10, rock[0].y + rock[0][3] / 2)
	call(r, "invoke_menu", `{"path":"Edit/Rename"}`)
	frames(r, 3)
	call(r, "input", `{"steps":[{"type":"text","text":"Boulder.scene"},{"type":"wait","frames":2},{"type":"key","name":"Enter"},{"type":"key","name":"Enter","down":false},{"type":"wait","frames":5}]}`)
	if !testing.expect(t, os.exists(project_path(r, "assets/Boulder.scene")) && !os.exists(project_path(r, "assets/Rock.scene")), "the rename gave the file its new name") do return
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 4)
	testing.expect(t, os.exists(project_path(r, "assets/Rock.scene")) && !os.exists(project_path(r, "assets/Boulder.scene")), "undo gives it the old name back")
	testing.expectf(t, _guid_of(r, "assets/Rock.scene.meta") == _ROCK_GUID, "with the same id: %v", _guid_of(r, "assets/Rock.scene.meta"))

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

@(private = "file")
_right_click :: proc(r: ^Run, x, y: f64) {
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"wait","frames":2}},{{"type":"up","button":"right"}},{{"type":"wait","frames":5}}]}}`, x, y))
}

// A pinned folder shows above the tree, takes the list there with a click,
// follows its folder when that moves, and is kept in the settings.
@(test)
project_pinned_folders :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Keep.scene", _scene("Keep"))
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	project_write(r, "assets/Box/Lid.scene", _scene("Lid"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Keep.scene"}`)
	frames(r, 5)

	art := _rects(r, "Art")
	if !testing.expectf(t, len(art) == 2, "Art is in the tree and the list: %v", art) do return
	_right_click(r, art[1].x + 10, art[1].y + art[1][3] / 2)
	pin, offered := item_rect(r, "popup", "Pin Folder")
	if !testing.expect(t, offered, "a folder's menu offers Pin Folder") do return
	click(r, pin.x + 10, pin.y + pin[3] / 2)
	frames(r, 3)
	art = _rects(r, "Art")
	if !testing.expectf(t, len(art) == 3, "the pinned Art shows above the tree too: %v", art) do return
	testing.expectf(t, art[0].y < art[1].y, "above the tree's row: %v", art)

	// Into Box, then the pin: the list is in Art again.
	box := _rects(r, "Box")
	if !testing.expectf(t, len(box) == 2, "Box is in the tree and the list: %v", box) do return
	click(r, box[0].x + 10, box[0].y + box[0][3] / 2)
	testing.expect(t, len(_rects(r, "Lid.scene")) == 1, "the list shows Box")
	art = _rects(r, "Art")
	click(r, art[0].x + 10, art[0].y + art[0][3] / 2)
	testing.expect(t, len(_rects(r, "Inside.scene")) == 1, "a click on the pin shows Art")

	// Art moves into Box: the pin follows it.
	roots := _rects(r, "assets")
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	art = _rects(r, "Art")
	box = _rects(r, "Box")
	if !testing.expectf(t, len(art) == 3 && len(box) == 2, "the root lists Art and Box: %v, %v", art, box) do return
	drag_mouse(r, art[2].x + 10, art[2].y + art[2][3] / 2, box[1].x + 10, box[1].y + box[1][3] / 2)
	frames(r, 4)
	if !testing.expect(t, os.exists(project_path(r, "assets/Box/Art/Inside.scene")), "Art moved into Box") do return
	art = _rects(r, "Art")
	if !testing.expectf(t, len(art) >= 1, "the pin is still there: %v", art) do return
	click(r, art[0].x + 10, art[0].y + art[0][3] / 2)
	testing.expect(t, len(_rects(r, "Inside.scene")) == 1, "and still shows Art, where it is now")

	editor_quit(r)
	pins, _ := at(project_json(r, "UserSettings/editor_settings.json"), "project_pins").(json.Array)
	testing.expectf(t, len(pins) == 1 && as_string(pins[0]) == "assets/Box/Art", "the pin is saved with the folder's new path: %v", pins)
}

// The search box's words used in place: the folder keeps its folders and
// shows the files that match, and a folder with no match is left out when
// the window's setting says so.
@(test)
project_filter_in_place :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Rock.scene", _scene("Rock"))
	project_write(r, "assets/Stone.scene", _scene("Stone"))
	project_write(r, "assets/Art/RockTwo.scene", _scene("RockTwo"))
	project_write(r, "assets/Empty/Other.scene", _scene("Other"))
	editor_start(r)
	call(r, "ping_asset", `{"path":"assets/Stone.scene"}`)
	frames(r, 5)

	TYPE :: `{{"steps":[{{"type":"text","text":%q}},{{"type":"wait","frames":4}}]}}`
	field, found := item_rect(r, "Project", "Search: name")
	if !testing.expect(t, found, "the Project window has its search field") do return
	// The field starts after the "+" button its line begins with.
	click(r, field.x + 60, field.y + field[3] / 2)
	call(r, "input", fmt.tprintf(TYPE, "rock"))

	// Searching: the hits of the whole project, as a flat list with paths.
	testing.expect(t, len(_rects(r, "Art/RockTwo.scene")) == 1 && len(_rects(r, "Rock.scene")) >= 1, "a search lists the hits of every folder")
	testing.expect(t, len(_rects(r, "Stone.scene")) == 0, "and no file that does not match")

	// Filtering: the same words in place.
	mode, has_mode := item_rect(r, "Project", "\ue152")
	if !testing.expect(t, has_mode, "the search box has its mode button") do return
	click(r, mode.x + mode[2] / 2, mode.y + mode[3] / 2)
	frames(r, 3)
	testing.expect(t, len(_rects(r, "Rock.scene")) == 1 && len(_rects(r, "Stone.scene")) == 0, "the folder shows its matching file only")
	testing.expect(t, len(_rects(r, "Art/RockTwo.scene")) == 0, "and no file of another folder")
	// In the tree and in the list each.
	testing.expectf(t, len(_rects(r, "Art")) == 2 && len(_rects(r, "Empty")) == 2, "its folders stay, the one with no match too: %v, %v", _rects(r, "Art"), _rects(r, "Empty"))

	// Into Art: the filter stays on.
	art := _rects(r, "Art")
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":4}}]}}`, art[1].x + 10, art[1].y + art[1][3] / 2))
	testing.expect(t, len(_rects(r, "RockTwo.scene")) == 1, "a folder opened under the filter shows its matching file")

	// With the window's setting, a folder with no match is left out of the list.
	call(r, "editor_setting", `{"name":"project_filter_hides","value":"true"}`)
	roots := _rects(r, "assets")
	click(r, roots[0].x + 10, roots[0].y + roots[0][3] / 2)
	testing.expectf(t, len(_rects(r, "Empty")) == 1 && len(_rects(r, "Art")) == 2, "Empty is in the tree only, Art in both: %v, %v", _rects(r, "Empty"), _rects(r, "Art"))

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// One column: the tree and the files in one list, a folder unfolding in
// place.
@(test)
project_one_column_layout :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Keep.scene", _scene("Keep"))
	project_write(r, "assets/Art/Inside.scene", _scene("Inside"))
	project_write(r, "assets/Art/Deep/Far.scene", _scene("Far"))
	editor_start(r)
	call(r, "editor_setting", `{"name":"project_one_column","value":"true"}`)
	call(r, "ping_asset", `{"path":"assets/Keep.scene"}`)
	frames(r, 5)

	// One list: the root open to its folder and its file, Art folded.
	art := _rects(r, "Art")
	keep := _rects(r, "Keep.scene")
	if !testing.expectf(t, len(art) == 1 && len(keep) == 1, "Art and Keep.scene are in the one list, once each: %v, %v", art, keep) do return
	testing.expect(t, len(_rects(r, "Inside.scene")) == 0, "Art is folded")

	// A double click unfolds Art in place: its folder and its file under it,
	// a step in.
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":4}}]}}`, art[0].x + 10, art[0].y + art[0][3] / 2))
	inside := _rects(r, "Inside.scene")
	deep := _rects(r, "Deep")
	art = _rects(r, "Art")
	if !testing.expectf(t, len(inside) == 1 && len(deep) == 1 && len(art) == 1, "Art shows Deep and Inside.scene under it: %v, %v", deep, inside) do return
	testing.expectf(t, inside[0].x > art[0].x + 5 && inside[0].y > art[0].y && deep[0].y < inside[0].y, "a step in, folders first: %v, %v against %v", deep[0], inside[0], art[0])
	testing.expect(t, len(_rects(r, "Keep.scene")) == 1, "the root's own file is still listed")

	// A file dragged onto a folder's row moves into it, as with two panes.
	keep = _rects(r, "Keep.scene")
	drag_mouse(r, keep[0].x + 10, keep[0].y + keep[0][3] / 2, deep[0].x + 10, deep[0].y + deep[0][3] / 2)
	frames(r, 4)
	testing.expect(t, os.exists(project_path(r, "assets/Art/Deep/Keep.scene")), "Keep.scene moved into Deep")

	// The arrow keys: Left on the open Art folds it.
	art = _rects(r, "Art")
	click(r, art[0].x + 10, art[0].y + art[0][3] / 2)
	call(r, "input", `{"steps":[{"type":"key","name":"LeftArrow"},{"type":"key","name":"LeftArrow","down":false},{"type":"wait","frames":4}]}`)
	testing.expect(t, len(_rects(r, "Inside.scene")) == 0, "Left folds the selected folder")
	call(r, "input", `{"steps":[{"type":"key","name":"RightArrow"},{"type":"key","name":"RightArrow","down":false},{"type":"wait","frames":4}]}`)
	testing.expect(t, len(_rects(r, "Inside.scene")) == 1, "Right unfolds it")

	// Another window asks for a file two folders down: the folders above it open.
	call(r, "ping_asset", `{"path":"assets/Art/Deep/Far.scene"}`)
	frames(r, 5)
	testing.expect(t, len(_rects(r, "Far.scene")) == 1, "a file asked for shows, its folders opened")

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
