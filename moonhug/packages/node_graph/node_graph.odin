package node_graph

// A pan/zoom node canvas, with no idea what a node MEANS.
//
// The caller owns its own data. Each frame it pushes nodes and links in, draws,
// and reads back what the user did. `user_handle` travels through untouched --
// the canvas never dereferences or interprets it, so one canvas serves tween
// trees, material graphs or anything else without knowing about any of them.
//
// This is the reason the package holds no domain types: the moment the canvas
// can name a Tween, every other user inherits that dependency.
//
// v1 is a READ-ONLY view: pan, zoom, select, and an auto-layout for trees.
// Dragging nodes, creating them and rewiring links are not here yet -- the
// caller's data is drawn, never mutated.

import "core:math"
import im "moonhug:external/odin-imgui"

// Caller-assigned node identity. The canvas passes it back in hit results and
// never looks inside it.
User_Handle :: distinct u64

// A node to draw this frame. Built fresh each frame by the caller -- the canvas
// keeps no copy, so there is no stale-data class of bug.
Node :: struct {
	user_handle: User_Handle,
	title:       string,
	subtitle:    string, // second line, dimmer; "" to omit

	// Canvas-space top-left. Auto-layout writes this back when used.
	position: [2]f32,
	size:     [2]f32, // {0,0} = measure from the text

	header_color: [4]f32,
	selected:     bool,
	dimmed:       bool, // drawn faded, for a node that will not run (skip)
}

// A parent -> child edge, by index into the caller's node slice. Indices rather
// than handles because the caller already has the array and this avoids a
// lookup per link per frame.
Link :: struct {
	from: int, // parent node index
	to:   int, // child node index
}

// What the user did this frame. Every field is "nothing happened" at zero.
Interaction :: struct {
	hovered:        User_Handle,
	hovered_valid:  bool,
	clicked:        User_Handle,
	clicked_valid:  bool,
	double_clicked: User_Handle,
	double_valid:   bool,
	// A click that landed on empty canvas -- callers use it to clear selection.
	clicked_empty: bool,
}

// Pan/zoom, owned by the caller so each graph view keeps its own viewport
// across frames without the package holding a registry keyed on anything.
View :: struct {
	pan:         [2]f32,
	zoom:        f32, // 0 is treated as 1, so a zero-value View is usable
	initialized: bool,
}

ZOOM_MIN :: 0.25
ZOOM_MAX :: 3.0

NODE_PAD :: [2]f32{10, 6}
NODE_MIN_W :: 120
HEADER_H :: 22
ROW_H :: 18

@(private)
_style :: struct {
	bg:        u32,
	grid:      u32,
	grid_bold: u32,
	node_bg:   u32,
	node_out:  u32,
	sel_out:   u32,
	link:      u32,
	text:      u32,
	text_dim:  u32,
} {
	bg        = 0xFF1E1E22,
	grid      = 0xFF2A2A30,
	grid_bold = 0xFF35353C,
	node_bg   = 0xFF2D2D34,
	node_out  = 0xFF4A4A54,
	sel_out   = 0xFFFFA030,
	link      = 0xFF8A8A96,
	text      = 0xFFE8E8EC,
	text_dim  = 0xFF9A9AA4,
}

view_zoom :: proc(v: ^View) -> f32 {
	if v == nil || v.zoom <= 0 do return 1
	return v.zoom
}

canvas_to_screen :: proc(v: ^View, origin: [2]f32, p: [2]f32) -> [2]f32 {
	z := view_zoom(v)
	return {origin.x + (p.x + v.pan.x) * z, origin.y + (p.y + v.pan.y) * z}
}

screen_to_canvas :: proc(v: ^View, origin: [2]f32, p: [2]f32) -> [2]f32 {
	z := view_zoom(v)
	return {(p.x - origin.x) / z - v.pan.x, (p.y - origin.y) / z - v.pan.y}
}

// Node size from its text, when the caller left size at zero. Measured at zoom
// 1 so a node does not change shape as the view scales.
measure_node :: proc(n: ^Node) -> [2]f32 {
	if n.size.x > 0 && n.size.y > 0 do return n.size
	w := f32(NODE_MIN_W)
	if n.title != "" {
		tw := im.CalcTextSize(_c(n.title)).x + NODE_PAD.x * 2
		if tw > w do w = tw
	}
	if n.subtitle != "" {
		sw := im.CalcTextSize(_c(n.subtitle)).x + NODE_PAD.x * 2
		if sw > w do w = sw
	}
	h := f32(HEADER_H)
	if n.subtitle != "" do h += ROW_H
	return {w, h}
}

// Arranges a TREE top-down: children below their parent, siblings side by side,
// subtrees packed so they never overlap. Writes back into node.position.
//
// A tree, not a general graph: it walks each root once and assumes a node has
// one parent. A tween tree is exactly that. A general DAG needs layering, which
// is a different algorithm and not written until something needs it.
layout_tree :: proc(nodes: []Node, links: []Link, x_gap: f32 = 30, y_gap: f32 = 40) {
	if len(nodes) == 0 do return

	has_parent := make([]bool, len(nodes), context.temp_allocator)
	for l in links {
		if l.to >= 0 && l.to < len(nodes) do has_parent[l.to] = true
	}

	cursor_x: f32 = 0
	for i in 0 ..< len(nodes) {
		if has_parent[i] do continue
		w := _layout_subtree(nodes, links, i, cursor_x, 0, x_gap, y_gap, 0)
		cursor_x += w + x_gap
	}
}

// Places one subtree with its left edge at `x`, returning the width it used.
// `depth` guards against a cycle in caller data -- a malformed graph must not
// hang the editor.
@(private)
_layout_subtree :: proc(nodes: []Node, links: []Link, idx: int, x, y, x_gap, y_gap: f32, depth: int) -> f32 {
	if depth > 64 do return 0
	size := measure_node(&nodes[idx])

	// Children are placed first, at a provisional left edge, to learn how wide
	// the block is. Only then can this subtree's width be known.
	child_x := x
	children_w: f32 = 0
	child_count := 0
	for l in links {
		if l.from != idx do continue
		if l.to < 0 || l.to >= len(nodes) do continue
		w := _layout_subtree(nodes, links, l.to, child_x, y + size.y + y_gap, x_gap, y_gap, depth + 1)
		child_x += w + x_gap
		children_w += w
		child_count += 1
	}
	if child_count > 1 do children_w += x_gap * f32(child_count - 1)

	total := max(size.x, children_w)

	// A parent WIDER than its children leaves the child block hanging off to
	// the left, because the children were placed from this subtree's left edge
	// before the parent's own width was taken into account. Shift the whole
	// block (and everything under it) to sit centred beneath the parent.
	if children_w > 0 && total > children_w {
		shift := (total - children_w) * 0.5
		for l in links {
			if l.from != idx do continue
			if l.to < 0 || l.to >= len(nodes) do continue
			_shift_subtree(nodes, links, l.to, shift, depth + 1)
		}
	}

	// Centre the parent over its children.
	nodes[idx].position = {x + (total - size.x) * 0.5, y}
	return total
}

// Moves a placed subtree along X. Used once a parent turns out to be wider
// than the block beneath it, which is only known after the children are placed.
@(private)
_shift_subtree :: proc(nodes: []Node, links: []Link, idx: int, dx: f32, depth: int) {
	if depth > 64 do return
	nodes[idx].position.x += dx
	for l in links {
		if l.from != idx do continue
		if l.to < 0 || l.to >= len(nodes) do continue
		_shift_subtree(nodes, links, l.to, dx, depth + 1)
	}
}

// Draws the graph into the current window and returns what the user did.
//
// `v` is caller-owned viewport state, mutated here by pan and zoom.
draw :: proc(v: ^View, nodes: []Node, links: []Link) -> (result: Interaction) {
	if v != nil && !v.initialized {
		v.zoom = 1
		v.initialized = true
	}

	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if avail.x < 16 || avail.y < 16 do return

	dl := im.GetWindowDrawList()
	p0 := [2]f32{origin.x, origin.y}
	p1 := [2]f32{origin.x + avail.x, origin.y + avail.y}

	im.DrawList_AddRectFilled(dl, im.Vec2{p0.x, p0.y}, im.Vec2{p1.x, p1.y}, _style.bg)
	im.DrawList_PushClipRect(dl, im.Vec2{p0.x, p0.y}, im.Vec2{p1.x, p1.y}, true)
	defer im.DrawList_PopClipRect(dl)

	// One invisible button owns the whole canvas, so panning and clicks are
	// reported against it rather than against whatever is underneath.
	im.InvisibleButton("##graph_canvas", avail)
	canvas_hovered := im.IsItemHovered()
	io := im.GetIO()

	_draw_grid(dl, v, p0, p1)

	// Middle-drag or space-less left-drag on empty space pans. Middle is the
	// unambiguous one -- left-drag is reserved for future box-select.
	if canvas_hovered && im.IsMouseDragging(.Middle) {
		d := io.MouseDelta
		z := view_zoom(v)
		v.pan.x += d.x / z
		v.pan.y += d.y / z
	}

	if canvas_hovered && io.MouseWheel != 0 {
		_zoom_at(v, p0, [2]f32{io.MousePos.x, io.MousePos.y}, io.MouseWheel)
	}

	for l in links {
		if l.from < 0 || l.from >= len(nodes) do continue
		if l.to < 0 || l.to >= len(nodes) do continue
		_draw_link(dl, v, p0, &nodes[l.from], &nodes[l.to])
	}

	mouse := [2]f32{io.MousePos.x, io.MousePos.y}
	hit := -1
	for i in 0 ..< len(nodes) {
		if _draw_node(dl, v, p0, &nodes[i], canvas_hovered, mouse) do hit = i
	}

	if hit >= 0 {
		result.hovered = nodes[hit].user_handle
		result.hovered_valid = true
		if im.IsMouseClicked(.Left) {
			result.clicked = nodes[hit].user_handle
			result.clicked_valid = true
		}
		if im.IsMouseDoubleClicked(.Left) {
			result.double_clicked = nodes[hit].user_handle
			result.double_valid = true
		}
	} else if canvas_hovered && im.IsMouseClicked(.Left) {
		result.clicked_empty = true
	}
	return
}

// Keeps the canvas point under the cursor fixed while the scale changes --
// without this the graph slides away from wherever the user is looking.
@(private)
_zoom_at :: proc(v: ^View, origin: [2]f32, mouse: [2]f32, wheel: f32) {
	before := screen_to_canvas(v, origin, mouse)
	z := view_zoom(v) * math.pow(1.1, wheel)
	v.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX)
	after := screen_to_canvas(v, origin, mouse)
	v.pan.x += after.x - before.x
	v.pan.y += after.y - before.y
}

@(private)
_draw_grid :: proc(dl: ^im.DrawList, v: ^View, p0, p1: [2]f32) {
	z := view_zoom(v)
	step := 32 * z
	if step < 8 do return // too dense to read, and expensive to draw

	ox := math.mod(v.pan.x * z, step)
	oy := math.mod(v.pan.y * z, step)

	// Every 4th line is brighter, so the scale stays legible while zooming.
	i := 0
	for x := p0.x + ox; x < p1.x; x += step {
		col := _style.grid_bold if i % 4 == 0 else _style.grid
		im.DrawList_AddLine(dl, im.Vec2{x, p0.y}, im.Vec2{x, p1.y}, col, 1)
		i += 1
	}
	i = 0
	for y := p0.y + oy; y < p1.y; y += step {
		col := _style.grid_bold if i % 4 == 0 else _style.grid
		im.DrawList_AddLine(dl, im.Vec2{p0.x, y}, im.Vec2{p1.x, y}, col, 1)
		i += 1
	}
}

// Parent bottom-centre to child top-centre, as a vertical bezier: the tree
// grows downward, so vertical tangents keep the curve from crossing siblings.
@(private)
_draw_link :: proc(dl: ^im.DrawList, v: ^View, origin: [2]f32, from, to: ^Node) {
	fs := measure_node(from)
	ts := measure_node(to)
	a := canvas_to_screen(v, origin, {from.position.x + fs.x * 0.5, from.position.y + fs.y})
	b := canvas_to_screen(v, origin, {to.position.x + ts.x * 0.5, to.position.y})
	dy := (b.y - a.y) * 0.5
	im.DrawList_AddBezierCubic(dl,
		im.Vec2{a.x, a.y}, im.Vec2{a.x, a.y + dy},
		im.Vec2{b.x, b.y - dy}, im.Vec2{b.x, b.y},
		_style.link, max(1, 1.5 * view_zoom(v)), 0)
}

// Returns whether the cursor is over this node.
@(private)
_draw_node :: proc(dl: ^im.DrawList, v: ^View, origin: [2]f32, n: ^Node, canvas_hovered: bool, mouse: [2]f32) -> bool {
	z := view_zoom(v)
	size := measure_node(n)
	a := canvas_to_screen(v, origin, n.position)
	b := canvas_to_screen(v, origin, {n.position.x + size.x, n.position.y + size.y})

	hovered := canvas_hovered && mouse.x >= a.x && mouse.x <= b.x && mouse.y >= a.y && mouse.y <= b.y

	bg := _style.node_bg
	hdr := _rgba(n.header_color)
	txt := _style.text
	sub := _style.text_dim
	if n.dimmed {
		bg = _fade(bg)
		hdr = _fade(hdr)
		txt = _fade(txt)
		sub = _fade(sub)
	}

	rounding := 4 * z
	im.DrawList_AddRectFilled(dl, im.Vec2{a.x, a.y}, im.Vec2{b.x, b.y}, bg, rounding)

	// Header band, rounded only on its top corners so it reads as part of the body.
	hb := a.y + HEADER_H * z
	im.DrawList_AddRectFilled(dl, im.Vec2{a.x, a.y}, im.Vec2{b.x, min(hb, b.y)}, hdr, rounding,
		im.DrawFlags_RoundCornersTopLeft | im.DrawFlags_RoundCornersTopRight)

	outline := _style.sel_out if n.selected else _style.node_out
	thickness := f32(2) if n.selected else 1
	im.DrawList_AddRect(dl, im.Vec2{a.x, a.y}, im.Vec2{b.x, b.y}, outline, rounding, thickness)

	// Text is only legible past a point, and CalcTextSize per node is not free.
	if z > 0.4 {
		tp := [2]f32{a.x + NODE_PAD.x * z, a.y + (HEADER_H * z - im.GetTextLineHeight()) * 0.5}
		im.DrawList_AddText(dl, im.Vec2{tp.x, tp.y}, txt, _c(n.title))
		if n.subtitle != "" {
			sp := [2]f32{a.x + NODE_PAD.x * z, hb + (ROW_H * z - im.GetTextLineHeight()) * 0.5}
			im.DrawList_AddText(dl, im.Vec2{sp.x, sp.y}, sub, _c(n.subtitle))
		}
	}
	return hovered
}

// Frames every node in view. Callers use it on open and on a "frame all" key.
frame_all :: proc(v: ^View, nodes: []Node, viewport: [2]f32) {
	if v == nil || len(nodes) == 0 || viewport.x < 1 || viewport.y < 1 do return

	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for i in 0 ..< len(nodes) {
		s := measure_node(&nodes[i])
		p := nodes[i].position
		lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
		hi.x = max(hi.x, p.x + s.x); hi.y = max(hi.y, p.y + s.y)
	}
	w := hi.x - lo.x
	h := hi.y - lo.y
	if w < 1 || h < 1 do return

	margin :: 40
	z := min((viewport.x - margin) / w, (viewport.y - margin) / h)
	v.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX)
	v.initialized = true
	// Centre the content: pan is in canvas space, so the offset divides by zoom.
	v.pan = {
		(viewport.x / v.zoom - w) * 0.5 - lo.x,
		(viewport.y / v.zoom - h) * 0.5 - lo.y,
	}
}

@(private)
_rgba :: proc(c: [4]f32) -> u32 {
	if c == {} do return 0xFF3A6EA5 // caller left it unset
	return im.GetColorU32ImVec4(im.Vec4{c.r, c.g, c.b, c.a})
}

@(private)
_fade :: proc(c: u32) -> u32 {
	// Halve alpha, keep RGB. imgui packs as ABGR.
	a := (c >> 24) & 0xFF
	return (c & 0x00FFFFFF) | ((a / 2) << 24)
}

// imgui takes cstrings. Graph strings are short and rebuilt per frame anyway,
// so the temp allocator is the right lifetime -- it is freed at frame end.
@(private)
_c :: proc(s: string) -> cstring {
	if s == "" do return ""
	buf := make([]byte, len(s) + 1, context.temp_allocator)
	copy(buf, s)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

// Stable node identity across rebuilds, for callers whose nodes have no id of
// their own: the PATH of child ordinals from the root. A pointer into caller
// data dies whenever the tree is rebuilt (an undo restore reallocates every
// node), and an index survives nothing. The path survives any rebuild that
// keeps the tree's shape -- which is exactly what undoing a value edit does.
//
// `parents` gives each node's parent index, -1 for a root, in an order where
// one parent's children appear in display order (a walk order is).

// The path of node `idx`, written into `out` root-first. Returns 0 when the
// node cannot reach a root within len(out) steps -- a cycle or a deeper tree
// than the caller allows -- so a truncated, wrong path is never handed back.
tree_path_of :: proc(parents: []int, idx: int, out: []i32) -> (depth: int) {
	if idx < 0 || idx >= len(parents) do return 0

	tmp := make([]i32, len(out), context.temp_allocator)
	n := 0
	cur := idx
	for parents[cur] >= 0 {
		if n >= len(out) do return 0
		p := parents[cur]
		if p >= len(parents) do return 0
		// The ordinal among this parent's children. Children appear in index
		// order, so it is the count of earlier siblings.
		ord: i32 = 0
		for j in 0 ..< cur {
			if parents[j] == p do ord += 1
		}
		tmp[n] = ord
		n += 1
		cur = p
	}
	for i in 0 ..< n {
		out[i] = tmp[n - 1 - i]
	}
	return n
}

// The node a path names, starting from `root`. -1 when the tree's shape no
// longer contains it. An empty path is the root itself.
tree_find_path :: proc(parents: []int, root: int, path: []i32) -> int {
	if root < 0 || root >= len(parents) do return -1
	cur := root
	for ord in path {
		next := -1
		n: i32 = 0
		for j in 0 ..< len(parents) {
			if parents[j] != cur do continue
			if n == ord {
				next = j
				break
			}
			n += 1
		}
		if next < 0 do return -1
		cur = next
	}
	return cur
}
