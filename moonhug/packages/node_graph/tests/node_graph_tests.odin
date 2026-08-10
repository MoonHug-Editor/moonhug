package node_graph_tests

// The canvas's pure geometry: coordinate transforms and tree layout. Drawing
// needs an imgui context, so it is not covered here -- these pin the arithmetic
// that decides WHERE things land, which is where node canvases usually go wrong.

import ng "moonhug:packages/node_graph"

import "core:testing"

// A round trip through the transform must land back where it started, at any
// pan and zoom. Getting these two out of step is the classic node-canvas bug:
// nodes draw in one place and hit-test in another.
@(test)
test_screen_canvas_round_trip :: proc(t: ^testing.T) {
	v := ng.View{pan = {37, -12}, zoom = 1.75, initialized = true}
	origin := [2]f32{100, 50}

	for p in ([][2]f32{{0, 0}, {10, 10}, {-250, 400}, {1e3, -1e3}}) {
		s := ng.canvas_to_screen(&v, origin, p)
		back := ng.screen_to_canvas(&v, origin, s)
		testing.expectf(t, abs(back.x - p.x) < 0.01 && abs(back.y - p.y) < 0.01,
			"round trip lost %v -> %v -> %v", p, s, back)
	}
}

// A zero View must behave as zoom 1 rather than collapsing everything to a
// point -- callers keep View in their own state and it starts zeroed.
@(test)
test_zero_view_is_identity_zoom :: proc(t: ^testing.T) {
	v := ng.View{}
	testing.expect_value(t, ng.view_zoom(&v), f32(1))
	p := ng.canvas_to_screen(&v, {0, 0}, {5, 7})
	testing.expect_value(t, p, [2]f32{5, 7})
}

// Children sit BELOW their parent, and siblings do not overlap. This is the
// whole point of the layout: a tween tree drawn with siblings on top of each
// other is unreadable.
@(test)
test_layout_tree_separates_siblings :: proc(t: ^testing.T) {
	nodes := []ng.Node{
		{user_handle = 1, title = "Sequence", size = {100, 30}},
		{user_handle = 2, title = "Move", size = {100, 30}},
		{user_handle = 3, title = "Scale", size = {100, 30}},
	}
	links := []ng.Link{{from = 0, to = 1}, {from = 0, to = 2}}

	ng.layout_tree(nodes, links)

	testing.expect(t, nodes[1].position.y > nodes[0].position.y, "child 1 below parent")
	testing.expect(t, nodes[2].position.y > nodes[0].position.y, "child 2 below parent")

	// Siblings share a row, and their boxes must not overlap on X.
	testing.expect_value(t, nodes[1].position.y, nodes[2].position.y)
	left, right := nodes[1], nodes[2]
	if left.position.x > right.position.x do left, right = right, left
	testing.expectf(t, left.position.x + left.size.x <= right.position.x,
		"siblings overlap: %v..%v and %v..", left.position.x, left.position.x + left.size.x, right.position.x)
}

// A cycle in caller data must not hang the editor. The layout is a tree walk,
// so a parent pointing back at an ancestor would recurse forever without the
// depth guard.
@(test)
test_layout_tree_survives_a_cycle :: proc(t: ^testing.T) {
	nodes := []ng.Node{
		{user_handle = 1, size = {80, 20}},
		{user_handle = 2, size = {80, 20}},
	}
	// 0 -> 1 -> 0: every node has a parent, so the walk starts nowhere, and any
	// entry into it must still terminate.
	links := []ng.Link{{from = 0, to = 1}, {from = 1, to = 0}}

	ng.layout_tree(nodes, links)
	testing.expect(t, true, "layout returned rather than recursing forever")
}

// Out-of-range link endpoints are ignored rather than indexing past the slice.
// The caller rebuilds nodes and links every frame, so a stale index during an
// edit is expected input, not a caller bug.
@(test)
test_layout_tree_ignores_bad_indices :: proc(t: ^testing.T) {
	nodes := []ng.Node{{user_handle = 1, size = {80, 20}}}
	links := []ng.Link{{from = 0, to = 99}, {from = -3, to = 0}}

	ng.layout_tree(nodes, links)
	testing.expect_value(t, nodes[0].position, [2]f32{0, 0})
}

// A parent WIDER than its children must still sit centred over them.
//
// Children are placed before the parent's own width is known, so they start at
// the subtree's left edge. Without a corrective shift the child block hangs off
// to the left of a wide parent -- visible immediately on a real tween tree,
// where "Sequence" is wider than its leaves.
@(test)
test_layout_centres_children_under_a_wide_parent :: proc(t: ^testing.T) {
	nodes := []ng.Node{
		{user_handle = 1, title = "Wide Parent", size = {400, 30}},
		{user_handle = 2, title = "a", size = {60, 30}},
		{user_handle = 3, title = "b", size = {60, 30}},
	}
	links := []ng.Link{{from = 0, to = 1}, {from = 0, to = 2}}

	ng.layout_tree(nodes, links)

	parent_mid := nodes[0].position.x + nodes[0].size.x * 0.5
	lo := min(nodes[1].position.x, nodes[2].position.x)
	hi := max(nodes[1].position.x + nodes[1].size.x, nodes[2].position.x + nodes[2].size.x)
	children_mid := (lo + hi) * 0.5

	testing.expectf(t, abs(parent_mid - children_mid) < 0.51,
		"parent centre %v vs children centre %v", parent_mid, children_mid)
}

// Path round trip: every node's path resolves back to itself. This is what
// keeps a selection alive across an undo -- the tree is rebuilt at new
// addresses, but a rebuild with the same SHAPE yields the same paths.
//
//        0
//       / \
//      1   3
//      |  / \
//      2 4   5
@(test)
test_tree_path_round_trip :: proc(t: ^testing.T) {
	parents := []int{-1, 0, 1, 0, 3, 3}

	for i in 0 ..< len(parents) {
		path: [8]i32
		depth := ng.tree_path_of(parents, i, path[:])
		got := ng.tree_find_path(parents, 0, path[:depth])
		testing.expectf(t, got == i, "node %v -> path %v -> node %v", i, path[:depth], got)
	}
}

// A path into a shape that no longer exists resolves to -1, never to a wrong
// node. Selection then clears instead of silently jumping elsewhere.
@(test)
test_tree_path_missing_shape_resolves_to_nothing :: proc(t: ^testing.T) {
	parents := []int{-1, 0} // root with one child
	path := []i32{1}        // "second child" -- there is none
	testing.expect_value(t, ng.tree_find_path(parents, 0, path), -1)

	deep := []i32{0, 0} // grandchild of a tree one level deep
	testing.expect_value(t, ng.tree_find_path(parents, 0, deep), -1)
}

// A parent cycle must return "no path" rather than climbing forever, and an
// empty path is the root itself.
@(test)
test_tree_path_cycle_and_root :: proc(t: ^testing.T) {
	cyclic := []int{1, 0}
	out: [8]i32
	testing.expect_value(t, ng.tree_path_of(cyclic, 0, out[:]), 0)

	parents := []int{-1, 0}
	testing.expect_value(t, ng.tree_find_path(parents, 0, nil), 0)
	depth := ng.tree_path_of(parents, 0, out[:])
	testing.expect_value(t, depth, 0)
}
