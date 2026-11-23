package scenarios

// The Hierarchy's rows: a drag between two rows puts an object there, a drag
// onto a row puts it under that row, a folded row opens while a drag rests on
// it, a scene's header folds its objects, and the arrow keys walk the rows.

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:time"

@(private = "file")
_ZERO :: `{"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}`

@(private = "file")
_ref :: proc(lid: int) -> string {
	return fmt.tprintf(`{{"pptr": {{"local_id": %d, "guid": "00000000-0000-0000-0000-000000000000"}}}}`, lid)
}

@(private = "file")
_object :: proc(lid: int, name: string, parent: string, children: string) -> string {
	return fmt.tprintf(`{{"local_id": %d, "name": %q, "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": %s, "children": [%s], "components": []}}`, lid, name, parent, children)
}

// The row of `name`: its name's rectangle, which starts after the row's
// indent, arrow and glyph.
@(private = "file")
_row :: proc(r: ^Run, name: string) -> (rect: [4]f64, shown: bool) {
	return item_rect(r, "Hierarchy", name)
}

@(test)
hierarchy_rows_reorder_reparent_and_fold :: proc(t: ^testing.T) {
	r := begin(t)
	// Top > Alpha, Beta > Kid, Gamma.
	project_write(r, "assets/Main.scene", fmt.tprintf(`{{"root": 1, "next_local_id": 6, "transforms": [%s, %s, %s, %s, %s], "nested_scenes": [], "breadcrumbs": [], "components": []}}`,
		_object(1, "Top", _ZERO, fmt.tprintf("%s, %s, %s", _ref(2), _ref(3), _ref(5))),
		_object(2, "Alpha", _ref(1), ""), _object(3, "Beta", _ref(1), _ref(4)), _object(4, "Kid", _ref(3), ""), _object(5, "Gamma", _ref(1), "")))
	project_write(r, "assets/Main.scene.meta", `{"guid": "5ce4e000-0000-4000-8000-0000000000c1"}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	window_open(r, "Hierarchy")
	frames(r, 5)

	alpha, a_shown := _row(r, "Alpha")
	beta, b_shown := _row(r, "Beta")
	gamma, g_shown := _row(r, "Gamma")
	if !testing.expect(t, a_shown && b_shown && g_shown, "the root's three objects are listed") do return
	testing.expect(t, alpha.y < beta.y && beta.y < gamma.y, "in the scene's order")
	_, kid_shown := _row(r, "Kid")
	testing.expect(t, !kid_shown, "Beta starts folded")

	// Gamma onto Alpha's top edge: before Alpha, at the same depth.
	drag_mouse(r, gamma.x + 10, gamma.y + gamma[3] / 2, alpha.x + 10, alpha.y)
	alpha, _ = _row(r, "Alpha")
	gamma, _ = _row(r, "Gamma")
	testing.expectf(t, gamma.y < alpha.y, "Gamma is above Alpha: %v against %v", gamma.y, alpha.y)
	testing.expectf(t, _same_depth(gamma, alpha), "and still a child of the root: %v against %v", gamma.x, alpha.x)

	// Alpha onto the middle of Gamma: under Gamma, which opens to show it.
	drag_mouse(r, alpha.x + 10, alpha.y + alpha[3] / 2, gamma.x + 10, gamma.y + gamma[3] / 2)
	alpha, a_shown = _row(r, "Alpha")
	gamma, _ = _row(r, "Gamma")
	if !testing.expect(t, a_shown, "Alpha shows under the opened Gamma") do return
	testing.expectf(t, alpha.x > gamma.x && alpha.y > gamma.y, "one step in, under Gamma: %v against %v", alpha, gamma)

	// A drag that rests on the folded Beta opens it, and Alpha lands after
	// Kid, inside Beta.
	beta, _ = _row(r, "Beta")
	drag_mouse(r, alpha.x + 10, alpha.y + alpha[3] / 2, beta.x + 10, beta.y + beta[3] / 2, release = false)
	kid: [4]f64
	for _ in 0 ..< 40 {
		time.sleep(50 * time.Millisecond)
		frames(r, 2)
		if kid, kid_shown = _row(r, "Kid"); kid_shown do break
	}
	if !testing.expect(t, kid_shown, "the drag resting on Beta opens it") {
		call(r, "input", `{"steps":[{"type":"up"}]}`)
		return
	}
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":3}},{{"type":"up"}},{{"type":"wait","frames":3}}]}}`, kid.x + 10, kid.y + kid[3]))
	alpha, _ = _row(r, "Alpha")
	kid, _ = _row(r, "Kid")
	testing.expectf(t, _same_depth(alpha, kid) && alpha.y > kid.y, "Alpha is Kid's next sibling: %v against %v", alpha, kid)

	// One undo step per drop.
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	alpha, _ = _row(r, "Alpha")
	gamma, _ = _row(r, "Gamma")
	testing.expectf(t, alpha.x > gamma.x && alpha.y > gamma.y && alpha.y < kid.y + 60, "undo puts Alpha back under Gamma: %v against %v", alpha, gamma)

	// A click selects, and Down then Up walk the rows.
	click(r, gamma.x + 10, gamma.y + gamma[3] / 2)
	testing.expectf(t, _selected(r, "Gamma"), "a click selects Gamma, got %v", at(call(r, "editor_state"), "selection"))
	call(r, "input", `{"steps":[{"type":"key","name":"Down"},{"type":"key","name":"Down","down":false},{"type":"wait","frames":3}]}`)
	testing.expectf(t, _selected(r, "Alpha"), "Down steps to its child Alpha, got %v", at(call(r, "editor_state"), "selection"))
	call(r, "input", `{"steps":[{"type":"key","name":"Up"},{"type":"key","name":"Up","down":false},{"type":"wait","frames":3}]}`)
	testing.expectf(t, _selected(r, "Gamma"), "Up steps back to Gamma, got %v", at(call(r, "editor_state"), "selection"))

	// The scene's header folds every object of the scene.
	scene_row, header_shown := _row(r, "Main *")
	if !testing.expect(t, header_shown, "the scene's header shows its name and the unsaved mark") do return
	click(r, scene_row.x - 26, scene_row.y + scene_row[3] / 2)
	_, g_shown = _row(r, "Gamma")
	testing.expect(t, !g_shown, "the header's arrow folds the scene's objects away")
	click(r, scene_row.x - 26, scene_row.y + scene_row[3] / 2)
	_, g_shown = _row(r, "Gamma")
	testing.expect(t, g_shown, "and brings them back")

	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// Two names that start at the same indent. A name's rectangle is measured
// from its glyphs, so it differs by a fraction of a point between names.
@(private = "file")
_same_depth :: proc(a, b: [4]f64) -> bool {
	return abs(a.x - b.x) < 3
}

// Whether `name` is the one selected object.
@(private = "file")
_selected :: proc(r: ^Run, name: string) -> bool {
	selection, is_list := at(call(r, "editor_state"), "selection").(json.Array)
	return is_list && len(selection) == 1 && as_string(selection[0]) == name
}
