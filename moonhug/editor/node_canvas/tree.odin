package node_canvas

// Helpers for a client whose nodes form a tree and are laid out, not placed
// by hand (the Tween Graph): a left-to-right layout that matches the canvas's
// ports (inputs on the left edge, outputs on the right), framing, and a stable
// node identity across rebuilds.
//
// A tree is given as `parents`: each node's parent index, -1 for a root, in
// an order where one parent's children appear in display order (a walk order
// is).

import im "moonhug:external/odin-imgui"

// Places a tree left to right: a child one column right of its parent,
// siblings stacked top to bottom, a parent centred on its children. `sizes`
// are the nodes' sizes in canvas units, `out` gets their top-left corners.
// A cycle in `parents` stops at depth 64 rather than hanging the editor.
canvas_layout_tree :: proc(parents: []int, sizes: []im.Vec2, out: []im.Vec2, x_gap: f32 = 60, y_gap: f32 = 16) {
	n := len(parents)
	if n == 0 do return
	col_w: f32
	for s in sizes do col_w = max(col_w, s.x)
	cursor_y: f32
	for i in 0 ..< n {
		if parents[i] >= 0 do continue
		h := _layout(parents, sizes, out, i, 0, cursor_y, col_w + x_gap, y_gap, 0)
		cursor_y += h + y_gap
	}
}

// Places the subtree of `idx` from `y` down and answers the height it took.
@(private = "file")
_layout :: proc(parents: []int, sizes: []im.Vec2, out: []im.Vec2, idx: int, x, y, col, y_gap: f32, depth: int) -> f32 {
	size := sizes[idx]
	if depth > 64 {
		out[idx] = {x, y}
		return size.y
	}
	child_y := y
	first, last := f32(-1), f32(-1)
	for j in 0 ..< len(parents) {
		if parents[j] != idx do continue
		h := _layout(parents, sizes, out, j, x + col, child_y, col, y_gap, depth + 1)
		mid := out[j].y + sizes[j].y * 0.5
		if first < 0 do first = mid
		last = mid
		child_y += h + y_gap
	}
	if first < 0 {
		out[idx] = {x, y}
		return size.y
	}
	children_h := child_y - y_gap - y
	// Centred on its children, and kept below `y` when it is the taller one.
	top := max((first + last) * 0.5 - size.y * 0.5, y)
	out[idx] = {x, top}
	return max(children_h, top + size.y - y)
}

// Zoom and pan that show every rect from `lo` to `hi` (canvas units) in the
// canvas, with a margin. The canvas's size is last frame's: call it from the
// frame after the first draw.
canvas_frame :: proc(cv: ^Node_Canvas, lo, hi: im.Vec2) {
	if cv.zoom == 0 do canvas_init(cv)
	if cv.size.x < 1 || cv.size.y < 1 do return
	w := max(hi.x - lo.x, 1)
	h := max(hi.y - lo.y, 1)
	margin :: 40
	cv.zoom = clamp(min((cv.size.x - margin) / w, (cv.size.y - margin) / h), CANVAS_ZOOM_MIN, 1)
	cv.pan = (cv.size / cv.zoom - im.Vec2{w, h}) * 0.5 - lo
}

// Stable node identity across rebuilds, for clients whose nodes have no id of
// their own: the PATH of child ordinals from the root. A pointer into client
// data dies whenever the tree is rebuilt (an undo restore reallocates every
// node), and an index survives nothing. The path survives any rebuild that
// keeps the tree's shape, which is exactly what undoing a value edit does.

// The path of node `idx`, written into `out` root-first. Returns 0 when the
// node cannot reach a root within len(out) steps (a cycle, or a deeper tree
// than the client allows), so a truncated, wrong path is never handed back.
tree_path_of :: proc(parents: []int, idx: int, out: []i32) -> (depth: int) {
	if idx < 0 || idx >= len(parents) do return 0
	tmp := make([]i32, len(out), context.temp_allocator)
	n := 0
	cur := idx
	for parents[cur] >= 0 {
		if n >= len(out) do return 0
		p := parents[cur]
		if p >= len(parents) do return 0
		// The ordinal among this parent's children: the count of earlier siblings.
		ord: i32 = 0
		for j in 0 ..< cur do if parents[j] == p do ord += 1
		tmp[n] = ord
		n += 1
		cur = p
	}
	for i in 0 ..< n do out[i] = tmp[n - 1 - i]
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
