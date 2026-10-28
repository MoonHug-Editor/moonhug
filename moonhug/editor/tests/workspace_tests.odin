package editor_tests

// Workspaces (editor/workspace): every provider's workspaces are listed and
// found by id, a change saves through the provider that holds it, a
// workspace whose provider no longer holds it is not found, and a frame goes
// with its last tab. A test provider keeps them in memory, so no settings
// file is written.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "moonhug:editor/workspace"

@(private = "file")
_store: struct {
	registered: bool,
	list:       [dynamic]^workspace.Workspace,
	saves:      int,
}

// A second store, and a provider that takes nothing in, for moves.
@(private = "file")
_store_b: struct {
	list: [dynamic]^workspace.Workspace,
}

@(private = "file")
_provider_register :: proc() {
	if _store.registered do return
	_store.registered = true
	workspace.provider_add({
		name   = "Test",
		list   = proc(out: ^[dynamic]^workspace.Workspace) { for ws in _store.list do append(out, ws) },
		save   = proc(ws: ^workspace.Workspace) { _store.saves += 1 },
		create = proc(name: string) -> ^workspace.Workspace {
			ws := workspace.make_workspace(name)
			append(&_store.list, ws)
			return ws
		},
		remove = proc(ws: ^workspace.Workspace) {
			for w, i in _store.list do if w == ws {
				ordered_remove(&_store.list, i)
				workspace.workspace_free(ws)
				return
			}
		},
		detach = proc(ws: ^workspace.Workspace) {
			for w, i in _store.list do if w == ws {
				ordered_remove(&_store.list, i)
				return
			}
		},
		adopt  = proc(ws: ^workspace.Workspace) -> bool {
			append(&_store.list, ws)
			return true
		},
	})
	workspace.provider_add({
		name   = "Test B",
		list   = proc(out: ^[dynamic]^workspace.Workspace) { for ws in _store_b.list do append(out, ws) },
		save   = proc(ws: ^workspace.Workspace) {},
		remove = proc(ws: ^workspace.Workspace) {
			for w, i in _store_b.list do if w == ws {
				ordered_remove(&_store_b.list, i)
				workspace.workspace_free(ws)
				return
			}
		},
		detach = proc(ws: ^workspace.Workspace) {
			for w, i in _store_b.list do if w == ws {
				ordered_remove(&_store_b.list, i)
				return
			}
		},
		adopt  = proc(ws: ^workspace.Workspace) -> bool {
			append(&_store_b.list, ws)
			return true
		},
	})
	workspace.provider_add({name = "Test Fixed", list = proc(out: ^[dynamic]^workspace.Workspace) {}})
}

@(private = "file")
_provider_index :: proc(name: string) -> int {
	for p, i in workspace.providers() do if p.name == name do return i
	return -1
}

@(test)
test_workspaces_from_providers :: proc(t: ^testing.T) {
	_provider_register()
	defer {
		delete(_store.list)
		_store.list = nil
	}
	p: workspace.Provider
	for pr in workspace.providers() do if pr.name == "Test" do p = pr
	ws := p.create("Layout")
	id := ws.id
	testing.expect(t, len(id) == 36, "a workspace has a unique id")
	e, ok := workspace.find(id)
	testing.expect(t, ok && e.ws == ws && workspace.providers()[e.provider].name == "Test", "found by id, with its provider")

	saves := _store.saves
	workspace.frame_add(ws, "Console/2", {0, 0, 300, 200})
	workspace.frame_add(ws, "Project/2", {320, 0, 300, 200})
	workspace.changed(ws)
	testing.expect_value(t, _store.saves, saves + 1)

	workspace.tab_remove(ws, 0, 0)
	testing.expect(t, len(ws.frames) == 1 && ws.frames[0].tabs[0] == "Project/2", "a frame goes with its last tab")

	// The provider no longer holds it (its scene closed): its id is not found.
	p.remove(ws)
	_, still := workspace.find(id)
	testing.expect(t, !still, "a workspace its provider does not hold is not found")
}

// The frame `id`'s position.
@(private = "file")
_pos :: proc(ws: ^workspace.Workspace, id: u32) -> [2]f32 {
	r := ws.frames[workspace.frame_index(ws, id)].rect
	return {r.x, r.y}
}

// Trees (workspace.layout): a child sits right of its parent, and each child
// of a frame takes the height of its subtree in the column, so a deeper
// child pushes its later siblings down. The tree moves with its root.
@(test)
test_workspace_chain_layout :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Chains")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {999, 999, 80, 40}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 60, 100}, b)
	d := workspace.frame_add(ws, "D", {0, 0, 70, 30}, a)
	testing.expect_value(t, ws.frames[2].parent, b)
	testing.expect_value(t, workspace.chain_root(ws, c), a)
	workspace.layout(ws)
	gx := 100 + workspace.CHAIN_COLUMN_GAP
	testing.expect_value(t, _pos(ws, b), [2]f32{gx, 0})
	testing.expect_value(t, _pos(ws, c), [2]f32{gx + 80 + workspace.CHAIN_COLUMN_GAP, 0})
	// B's subtree is as tall as C, taller than B itself.
	testing.expect_value(t, _pos(ws, d), [2]f32{gx, 100 + workspace.CHAIN_ROW_GAP})

	// The tree moves with the frame heading it.
	ws.frames[0].rect.x, ws.frames[0].rect.y = 500, 300
	workspace.layout(ws)
	testing.expect_value(t, _pos(ws, c), [2]f32{600 + 2 * workspace.CHAIN_COLUMN_GAP + 80, 300})
	testing.expect_value(t, _pos(ws, d), [2]f32{600 + workspace.CHAIN_COLUMN_GAP, 300 + 100 + workspace.CHAIN_ROW_GAP})

	// Unchained, a frame stays where it is and heads its own tree, with its
	// children: the rest stacks up in the column.
	workspace.chain(ws, b, 0)
	testing.expect_value(t, ws.frames[workspace.frame_index(ws, b)].parent, u32(0))
	testing.expect_value(t, workspace.chain_root(ws, c), b)
	workspace.layout(ws, a)
	testing.expect_value(t, _pos(ws, d), [2]f32{600 + workspace.CHAIN_COLUMN_GAP, 300})
}

// A tree's box holds all its frames: another tree near its grandchild parts
// from it.
@(test)
test_workspace_trees_keep_apart :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Trees")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 100, 50}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 100, 50}, b)
	z := workspace.frame_add(ws, "Z", {260, 60, 100, 50})
	workspace.layout(ws, a)
	// C spans x 260..360, y 0..50. Z, below it, moves down the shortest way.
	testing.expect_value(t, _pos(ws, c), [2]f32{260, 0})
	testing.expect_value(t, _pos(ws, z), [2]f32{260, 50 + workspace.CHAIN_SPACING})
}

// A chain nearer another than CHAIN_SPACING moves away by the shortest way.
// The pinned chain stays, otherwise the later one moves.
@(test)
test_workspace_chains_keep_apart :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Apart")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 100})
	d := workspace.frame_add(ws, "D", {110, 0, 100, 100})
	testing.expect(t, workspace.layout(ws, a), "the chains part")
	testing.expect_value(t, ws.frames[0].rect.x, f32(0))
	testing.expect_value(t, ws.frames[1].rect.x, 100 + workspace.CHAIN_SPACING)
	testing.expect(t, !workspace.layout(ws, a), "apart, nothing moves")

	// D dragged onto A: A moves out of its way, to the left here.
	ws.frames[1].rect.x = 50
	workspace.layout(ws, d)
	testing.expect_value(t, ws.frames[1].rect.x, f32(50))
	testing.expect_value(t, ws.frames[0].rect.x, 50 - workspace.CHAIN_SPACING - 100)
}

// fix makes whatever a provider loaded valid: unique ids, and no parent that
// is missing. A chained parent stays: trees have any depth.
@(test)
test_workspace_fix :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Fix")
	defer workspace.workspace_free(ws)
	append(&ws.frames, workspace.Frame{id = 0}, workspace.Frame{id = 5}, workspace.Frame{id = 5}, workspace.Frame{id = 7, parent = 5}, workspace.Frame{id = 8, parent = 7}, workspace.Frame{id = 9, parent = 42})
	for &f in ws.frames do append(&f.tabs, _clone("View"))
	testing.expect(t, workspace.fix(ws), "it repairs")
	for f, i in ws.frames {
		testing.expect(t, f.id != 0, "every frame has an id")
		for g in ws.frames[:i] do testing.expect(t, g.id != f.id, "ids are unique")
	}
	testing.expect_value(t, ws.frames[3].parent, u32(5))
	testing.expect_value(t, ws.frames[4].parent, u32(7)) // its parent is chained, which is fine
	testing.expect_value(t, ws.frames[5].parent, u32(0)) // its parent is missing
	testing.expect(t, !workspace.fix(ws), "valid now")
}

// Chaining a frame brings its subtree along. A root that goes leaves its
// children where they are, each heading its own tree, with their own
// children still under them.
@(test)
test_workspace_chain_edits :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Edits")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 80, 40}, a)
	x := workspace.frame_add(ws, "X", {800, 0, 100, 50})
	workspace.chain(ws, a, x)
	// A chained frame and its subtree go to the end of the list: the last child.
	testing.expect_value(t, ws.frames[workspace.frame_index(ws, a)].parent, x)
	testing.expect_value(t, ws.frames[workspace.frame_index(ws, b)].parent, a)
	testing.expect_value(t, workspace.frame_index(ws, x), 0)

	workspace.layout(ws, x)
	before := ws.frames[workspace.frame_index(ws, a)].rect
	workspace.tab_remove(ws, workspace.frame_index(ws, x), 0) // X goes with its only tab
	testing.expect_value(t, len(ws.frames), 2)
	ai, bi := workspace.frame_index(ws, a), workspace.frame_index(ws, b)
	testing.expect_value(t, ws.frames[ai].parent, u32(0))
	testing.expect_value(t, ws.frames[bi].parent, a)
	testing.expect_value(t, ws.frames[ai].rect, before)
}

// A middle frame that goes hands its children to its parent, at its own
// place among its siblings, in their order: the tree condenses.
@(test)
test_workspace_remove_condenses :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Condense")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 80, 40}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 80, 40}) // made before X: its place comes from the list
	x := workspace.frame_add(ws, "X", {0, 0, 80, 40}, a)
	workspace.chain(ws, c, x)
	e := workspace.frame_add(ws, "E", {0, 0, 80, 40}, x)
	g := workspace.frame_add(ws, "G", {0, 0, 80, 40}, e)
	f := workspace.frame_add(ws, "F", {0, 0, 80, 40}, a)

	workspace.tab_remove(ws, workspace.frame_index(ws, x), 0)
	kids := make([dynamic]u32, context.temp_allocator)
	for fr in ws.frames do if fr.parent == a do append(&kids, fr.id)
	testing.expect_value(t, len(kids), 4)
	if len(kids) == 4 do testing.expect_value(t, [4]u32{kids[0], kids[1], kids[2], kids[3]}, [4]u32{b, c, e, f})
	testing.expect_value(t, ws.frames[workspace.frame_index(ws, g)].parent, e)
	testing.expect_value(t, workspace.sibling_index(ws, e), 2)

	workspace.layout(ws)
	gx := 100 + workspace.CHAIN_COLUMN_GAP
	testing.expect_value(t, _pos(ws, c), [2]f32{gx, 40 + workspace.CHAIN_ROW_GAP})
	testing.expect_value(t, _pos(ws, f), [2]f32{gx, 3 * (40 + workspace.CHAIN_ROW_GAP)})
}

// chain refuses a parent that is the frame itself or below it, and changes
// nothing.
@(test)
test_workspace_chain_refuses_cycle :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Cycle")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 100, 50}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 100, 50}, b)
	testing.expect(t, workspace.is_ancestor(ws, a, c), "A is above C")
	testing.expect(t, !workspace.is_ancestor(ws, c, a), "C is not above A")
	testing.expect(t, !workspace.is_ancestor(ws, a, a), "a frame is not its own ancestor")
	workspace.chain(ws, a, c)
	workspace.chain(ws, a, b)
	workspace.chain(ws, b, b)
	workspace.chain(ws, b, 999)
	testing.expect_value(t, [3]u32{ws.frames[0].parent, ws.frames[1].parent, ws.frames[2].parent}, [3]u32{0, a, b})

	// Moving C up to A is fine.
	workspace.chain(ws, c, a)
	testing.expect_value(t, ws.frames[2].parent, a)
}

// fix breaks a cycle a provider saved: the first frame of it in the list
// heads its tree, and the rest keep their parents.
@(test)
test_workspace_fix_breaks_cycle :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Saved cycle")
	defer workspace.workspace_free(ws)
	append(&ws.frames, workspace.Frame{id = 1, parent = 3}, workspace.Frame{id = 2, parent = 1}, workspace.Frame{id = 3, parent = 2}, workspace.Frame{id = 4, parent = 2}, workspace.Frame{id = 5, parent = 5})
	for &f in ws.frames do append(&f.tabs, _clone("View"))
	testing.expect(t, workspace.fix(ws), "it repairs")
	got: [5]u32
	for f, i in ws.frames do got[i] = f.parent
	testing.expect_value(t, got, [5]u32{0, 1, 2, 2, 0})
	testing.expect_value(t, workspace.chain_root(ws, 4), u32(1))
	testing.expect(t, !workspace.fix(ws), "valid now")
	workspace.layout(ws)
}

// subtree lists a frame and every frame below it, a parent before its
// children, siblings in their order.
@(test)
test_workspace_subtree_order :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Subtree")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 100, 50}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 100, 50}, b)
	d := workspace.frame_add(ws, "D", {0, 0, 100, 50}, a)
	e := workspace.frame_add(ws, "E", {0, 0, 100, 50}, c)
	z := workspace.frame_add(ws, "Z", {0, 0, 100, 50})
	f := workspace.frame_add(ws, "F", {0, 0, 100, 50}, b)
	testing.expect(t, slice.equal(workspace.subtree(ws, a), []u32{a, b, c, e, f, d}), "the whole tree, depth first")
	testing.expect(t, slice.equal(workspace.subtree(ws, b), []u32{b, c, e, f}), "a subtree")
	testing.expect(t, slice.equal(workspace.subtree(ws, z), []u32{z}), "a lone frame")
	testing.expect_value(t, len(workspace.subtree(ws, 999)), 0)
}

// A child moves among its siblings, and the layout stacks it in its new place.
@(test)
test_workspace_sibling_move :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Order")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {0, 0, 80, 40}, a)
	x := workspace.frame_add(ws, "X", {800, 0, 100, 50})
	c := workspace.frame_add(ws, "C", {0, 0, 80, 60}, a)
	d := workspace.frame_add(ws, "D", {0, 0, 80, 30}, a)
	testing.expect_value(t, workspace.sibling_index(ws, d), 2)
	testing.expect_value(t, workspace.sibling_index(ws, x), -1)

	workspace.sibling_move(ws, d, 0)
	order :: proc(ws: ^workspace.Workspace, p: u32) -> [3]u32 {
		out: [3]u32
		n := 0
		for f in ws.frames do if f.parent == p && n < 3 { out[n] = f.id; n += 1 }
		return out
	}
	testing.expect_value(t, order(ws, a), [3]u32{d, b, c})
	workspace.sibling_move(ws, d, 2)
	testing.expect_value(t, order(ws, a), [3]u32{b, c, d})
	workspace.sibling_move(ws, b, 1)
	testing.expect_value(t, order(ws, a), [3]u32{c, b, d})

	workspace.layout(ws, a)
	y := [3]f32{}
	for f in ws.frames do switch f.id {
	case c: y[0] = f.rect.y
	case b: y[1] = f.rect.y
	case d: y[2] = f.rect.y
	}
	testing.expect_value(t, y, [3]f32{0, 60 + workspace.CHAIN_ROW_GAP, 60 + 40 + 2 * workspace.CHAIN_ROW_GAP})
}

// Save In: a workspace moves to another provider with its id, name and
// frames, so a Workspace view showing it goes on showing it. A provider that
// takes nothing in is refused, and the workspace stays where it was.
@(test)
test_workspace_moves_between_providers :: proc(t: ^testing.T) {
	_provider_register()
	defer {
		delete(_store.list)
		_store.list = nil
		delete(_store_b.list)
		_store_b.list = nil
	}
	a, b, fixed := _provider_index("Test"), _provider_index("Test B"), _provider_index("Test Fixed")
	ws := workspace.providers()[a].create("Moving")
	id := ws.id
	workspace.frame_add(ws, "Console/2", {0, 0, 300, 200})
	testing.expect(t, workspace.can_move_to(ws, b), "it can move to B")
	testing.expect(t, !workspace.can_move_to(ws, a), "it is in A already")
	testing.expect(t, !workspace.can_move_to(ws, fixed), "that provider takes nothing in")
	testing.expect(t, !workspace.move_to(ws, fixed), "a refused move does nothing")

	testing.expect(t, workspace.move_to(ws, b), "it moves to B")
	e, ok := workspace.find(id)
	testing.expect(t, ok && e.ws == ws && workspace.providers()[e.provider].name == "Test B", "found by its id, in B")
	testing.expect(t, len(ws.frames) == 1 && ws.name == "Moving", "with its frames and name")
	testing.expect(t, len(_store.list) == 0 && len(_store_b.list) == 1, "A let it go, B holds it")
	workspace.providers()[b].remove(ws)
}

// Removing a tab keeps the same tab active: one before it shifts the active
// index down, the active one itself leaves the next one active.
@(test)
test_workspace_tab_remove_keeps_active :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Tabs")
	defer workspace.workspace_free(ws)
	workspace.frame_add(ws, "A", {0, 0, 100, 50})
	f := &ws.frames[0]
	append(&f.tabs, "B", "C", "D")
	for &k in f.tabs[1:] do k = _clone(k)
	f.active = 2 // C
	workspace.tab_remove(ws, 0, 0)
	testing.expect_value(t, f.tabs[f.active], "C")
	workspace.tab_remove(ws, 0, 2) // D, after it
	testing.expect_value(t, f.tabs[f.active], "C")
	workspace.tab_remove(ws, 0, f.active) // C itself: the last tab, the one before it shows
	testing.expect_value(t, f.tabs[f.active], "B")
}

// A tab key the workspace owns: it frees them on the default allocator.
@(private = "file")
_clone :: proc(s: string) -> string {
	return strings.clone(s, runtime.default_allocator())
}

// fix drops a frame with no tabs, and the frames chained to it head their
// own chains.
@(test)
test_workspace_fix_drops_empty_frames :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Empty")
	defer workspace.workspace_free(ws)
	append(&ws.frames, workspace.Frame{id = 1})
	c := workspace.frame_add(ws, "C", {0, 0, 100, 50})
	ws.frames[1].parent = 1
	testing.expect(t, workspace.fix(ws), "it repairs")
	testing.expect_value(t, len(ws.frames), 1)
	testing.expect_value(t, ws.frames[0].id, c)
	testing.expect_value(t, ws.frames[0].parent, u32(0))
}

// A workspaces file that does not parse loads no workspaces and is never
// written over: the store is broken and refuses to save. A good file loads.
@(test)
test_workspace_file_store_malformed :: proc(t: ^testing.T) {
	dir, derr := os.temp_directory(context.temp_allocator)
	testing.expect(t, derr == nil, "a temp directory")
	if derr != nil do return
	path, _ := filepath.join({dir, "moonhug_workspaces_test.json"}, context.temp_allocator)
	defer os.remove(path)
	BAD :: `{"workspaces": [{"id": "x", "name": `
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(BAD)) == nil, "the file is written")

	s := workspace.File_Store{path = path}
	defer workspace.file_store_free(&s)
	workspace.file_store_load(&s)
	testing.expect(t, s.broken, "the store is broken")
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, !workspace.file_store_save(&s), "a broken store is not saved")
	bytes, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil && string(bytes) == BAD, "the file stays as it was")

	GOOD :: `{"workspaces": [{"id": "x", "name": "Good", "frames": [{"id": 1, "tabs": ["Console"]}]}]}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(GOOD)) == nil, "the file is written")
	workspace.file_store_free(&s)
	workspace.file_store_load(&s)
	testing.expect(t, !s.broken && len(s.list) == 1 && s.list[0].name == "Good", "a good file loads")
	testing.expect(t, workspace.file_store_save(&s), "and saves")
}
