package scenarios

// The node canvas's editing (moonhug/editor/node_canvas), through the Shader
// Graph window: a link dropped on empty canvas offers nodes to connect, a
// box selects nodes, a drag moves the selection, Delete removes it, and a
// node's fold arrow collapses it. Driven with real input, read back from the
// graph's document.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

// Surface, a UV node, and two Add nodes under it.
@(private = "file")
_GRAPH :: `{
  "__type_guid": "63d79718-e863-4004-a6e3-d8e372be9476",
  "properties": [],
  "nodes": [
    {"id": 1, "kind": "Surface", "position": [700.0, 40.0], "property": "", "values": [[0.8, 0.8, 0.8, 1.0], [1.0, 0.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.5, 0.0, 0.0, 0.0], [1.0, 0.0, 0.0, 0.0]]},
    {"id": 2, "kind": "UV", "position": [40.0, 40.0], "property": "", "values": []},
    {"id": 3, "kind": "Add", "position": [40.0, 200.0], "property": "", "values": [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]},
    {"id": 4, "kind": "Add", "position": [40.0, 340.0], "property": "", "values": [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]}
  ],
  "links": [],
  "next_id": 5
}`

@(private = "file")
_PATH :: "assets/Test.shadergraph"

@(private = "file")
_graph :: proc(r: ^Run) -> json.Value {
	return at(call(r, "asset_document", fmt.tprintf(`{{"path":%q}}`, _PATH)), "values")
}

// The node of id `id` in the graph's document, nil when gone.
@(private = "file")
_node :: proc(g: json.Value, id: i64) -> json.Value {
	nodes, _ := at(g, "nodes").(json.Array)
	for n in nodes do if as_int(at(n, "id")) == id do return n
	return nil
}

// The topmost drawn text `label` in the graph's window (titled by the
// graph): a node's title.
@(private = "file")
_title :: proc(r: ^Run, label: string) -> (rect: [4]f64, ok: bool) {
	res, code, _ := call_raw(r, "item_rect", fmt.tprintf(`{{"window":"Test","label":%q}}`, label))
	if code != "" do return
	matches, _ := at(res, "matches").(json.Array)
	best := -1.0
	for m in matches {
		if as_string(at(m, "label")) != label do continue
		y := as_f64(at(m, "y"))
		if best < 0 || y < best {
			best = y
			rect = {as_f64(at(m, "x")), y, as_f64(at(m, "width")), as_f64(at(m, "height"))}
			ok = true
		}
	}
	return
}

@(test)
node_canvas_edits_a_shader_graph :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, _PATH, _GRAPH)
	editor_start(r)
	call(r, "ping_asset", fmt.tprintf(`{{"path":%q}}`, _PATH))
	frames(r, 3)
	row, listed := item_rect(r, "Project", "Test.shadergraph")
	if !testing.expectf(t, listed, "the Project window lists the graph") do return
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":4}}]}}`, row.x + 20, row.y + row[3] / 2))
	call(r, "window_place", `{"window":"Test","x":40,"y":40,"width":1300,"height":760}`)
	frames(r, 6)

	// Canvas units are points at zoom 1. A node is 184 wide, its header 24
	// high, its rows 18 from 7 below the header.
	uv, found := _title(r, "UV")
	if !testing.expectf(t, found, "the canvas shows the UV node") do return
	left := uv.x + uv[2] / 2 - 92 // the node's left edge
	top := uv.y + uv[3] / 2 - 12   // its top
	// UV's one row is its output, on the right edge.
	out := [2]f64{left + 184, top + 24 + 7 + 9}

	// A link from UV's output dropped on empty canvas: the add menu opens
	// with what takes it, and Math > Add makes a linked node.
	drag_mouse(r, out.x, out.y, out.x + 260, out.y + 420)
	math, shown := item_rect(r, "popup", "Math")
	if !testing.expectf(t, shown, "the dropped link opens the add-node menu") do return
	click(r, math.x + 10, math.y + math[3] / 2)
	add, offered := item_rect(r, "popup", "Add")
	if !testing.expectf(t, offered, "Math offers Add") do return
	click(r, add.x + 10, add.y + add[3] / 2)
	frames(r, 3)
	g := _graph(r)
	testing.expectf(t, _node(g, 5) != nil, "the picked node is added")
	links, _ := at(g, "links").(json.Array)
	linked := false
	for l in links do if as_int(at(l, "from_node")) == 2 && as_int(at(l, "to_node")) == 5 && as_int(at(l, "to_port")) == 0 do linked = true
	testing.expectf(t, linked, "and linked from UV to its first input: %v", links)

	// A box around the two Add nodes selects both, a drag on one moves both.
	box_from := [2]f64{left - 20, top + 160 - 10}
	drag_mouse(r, box_from.x, box_from.y, left + 200, top + 300 + 90)
	before3 := as_f64(at(_node(_graph(r), 3), "position", 0))
	before4 := as_f64(at(_node(_graph(r), 4), "position", 0))
	// The first Add's header: canvas (40, 200), 160 below UV's.
	drag_mouse(r, left + 120, top + 160 + 12, left + 220, top + 160 + 12)
	g = _graph(r)
	d3 := as_f64(at(_node(g, 3), "position", 0)) - before3
	d4 := as_f64(at(_node(g, 4), "position", 0)) - before4
	testing.expectf(t, d3 > 50 && abs(d3 - d4) < 0.01, "both selected nodes moved by the same amount: %v and %v", d3, d4)

	// Delete removes both.
	call(r, "input", `{"steps":[{"type":"key","name":"Delete"},{"type":"key","name":"Delete","down":false},{"type":"wait","frames":3}]}`)
	g = _graph(r)
	testing.expectf(t, _node(g, 3) == nil && _node(g, 4) == nil, "Delete removes the selected nodes")
	testing.expectf(t, _node(g, 2) != nil && _node(g, 5) != nil, "and only them")

	// The fold arrow at the left of UV's header collapses it.
	click(r, left + 12, top + 12)
	frames(r, 2)
	testing.expectf(t, as_bool(at(_node(_graph(r), 2), "collapsed")), "the fold arrow collapses the node")

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
