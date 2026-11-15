package editor_tests

// The node canvas's tree helpers (editor/node_canvas/tree.odin): the left to
// right layout, framing, and the path that names a node across rebuilds.

import "core:testing"
import im "moonhug:external/odin-imgui"
import nc "moonhug:editor/node_canvas"

@(private = "file")
_layout :: proc(parents: []int) -> []im.Vec2 {
	sizes := make([]im.Vec2, len(parents), context.temp_allocator)
	for &s in sizes do s = nc.canvas_node_size(1)
	out := make([]im.Vec2, len(parents), context.temp_allocator)
	nc.canvas_layout_tree(parents, sizes, out)
	return out
}

//        0
//       / \
//      1   3
//      |  / \
//      2 4   5
@(test)
test_canvas_layout_tree_columns_and_rows :: proc(t: ^testing.T) {
	parents := []int{-1, 0, 1, 0, 3, 3}
	pos := _layout(parents)
	h := nc.canvas_node_size(1).y

	// A child sits one column right of its parent.
	testing.expect(t, pos[1].x > pos[0].x && pos[2].x > pos[1].x && pos[1].x == pos[3].x)
	testing.expect(t, pos[2].x == pos[4].x && pos[4].x == pos[5].x)
	// Siblings and cousins never overlap.
	for a in 1 ..< len(pos) do for b in a + 1 ..< len(pos) {
		if pos[a].x != pos[b].x do continue
		testing.expectf(t, abs(pos[a].y - pos[b].y) >= h, "nodes %d and %d overlap", a, b)
	}
	// A parent is centred on its children.
	testing.expect(t, abs((pos[3].y + h * 0.5) - ((pos[4].y + pos[5].y) * 0.5 + h * 0.5)) < 0.01)
}

// A cycle in the parents does not hang the editor.
@(test)
test_canvas_layout_tree_survives_a_cycle :: proc(t: ^testing.T) {
	_ = _layout([]int{1, 0})
	_ = _layout([]int{-1, 1})
}

@(test)
test_tree_path_round_trip :: proc(t: ^testing.T) {
	parents := []int{-1, 0, 1, 0, 3, 3}
	for i in 0 ..< len(parents) {
		path: [8]i32
		depth := nc.tree_path_of(parents, i, path[:])
		got := nc.tree_find_path(parents, 0, path[:depth])
		testing.expectf(t, got == i, "node %v -> path %v -> node %v", i, path[:depth], got)
	}
}

// A path into a shape that no longer exists resolves to -1, never to a wrong
// node. Selection then clears instead of silently jumping elsewhere.
@(test)
test_tree_path_missing_shape_resolves_to_nothing :: proc(t: ^testing.T) {
	parents := []int{-1, 0}
	testing.expect_value(t, nc.tree_find_path(parents, 0, []i32{1}), -1)
	testing.expect_value(t, nc.tree_find_path(parents, 0, []i32{0, 0}), -1)
}

// A parent cycle returns "no path" rather than climbing forever, and an empty
// path is the root itself.
@(test)
test_tree_path_cycle_and_root :: proc(t: ^testing.T) {
	out: [8]i32
	testing.expect_value(t, nc.tree_path_of([]int{1, 0}, 0, out[:]), 0)
	parents := []int{-1, 0}
	testing.expect_value(t, nc.tree_find_path(parents, 0, nil), 0)
	testing.expect_value(t, nc.tree_path_of(parents, 0, out[:]), 0)
}
