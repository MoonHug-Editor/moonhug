package editor_tests

// Workspaces (editor/workspace): every provider's workspaces are listed and
// found by id, a change saves through the provider that holds it, a
// workspace whose provider no longer holds it is not found, and a frame goes
// with its last tab. A test provider keeps them in memory, so no settings
// file is written.

import "core:testing"
import "moonhug:editor/workspace"

@(private = "file")
_store: struct {
	registered: bool,
	list:       [dynamic]^workspace.Workspace,
	saves:      int,
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
	})
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

// Chains (workspace.layout): a chained frame sits right of its parent, under
// the one before it, and a frame chained to a chained frame joins its
// parent, so chains stay one level deep.
@(test)
test_workspace_chain_layout :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Chains")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	b := workspace.frame_add(ws, "B", {999, 999, 80, 40}, a)
	c := workspace.frame_add(ws, "C", {0, 0, 60, 30}, b)
	testing.expect_value(t, ws.frames[2].parent, a)
	workspace.layout(ws)
	gx := 100 + workspace.CHAIN_COLUMN_GAP
	testing.expect_value(t, [2]f32{ws.frames[1].rect.x, ws.frames[1].rect.y}, [2]f32{gx, 0})
	testing.expect_value(t, [2]f32{ws.frames[2].rect.x, ws.frames[2].rect.y}, [2]f32{gx, 40 + workspace.CHAIN_ROW_GAP})

	// The chain moves with the frame heading it.
	ws.frames[0].rect.x, ws.frames[0].rect.y = 500, 300
	workspace.layout(ws)
	testing.expect_value(t, [2]f32{ws.frames[2].rect.x, ws.frames[2].rect.y}, [2]f32{600 + workspace.CHAIN_COLUMN_GAP, 300 + 40 + workspace.CHAIN_ROW_GAP})

	// Unchained, a frame stays where it is and heads its own chain.
	workspace.chain(ws, c, 0)
	testing.expect_value(t, ws.frames[2].parent, u32(0))
	testing.expect_value(t, workspace.chain_root(ws, c), c)
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
// is missing or chained.
@(test)
test_workspace_fix :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Fix")
	defer workspace.workspace_free(ws)
	append(&ws.frames, workspace.Frame{id = 0}, workspace.Frame{id = 5}, workspace.Frame{id = 5}, workspace.Frame{id = 7, parent = 5}, workspace.Frame{id = 8, parent = 7}, workspace.Frame{id = 9, parent = 42})
	testing.expect(t, workspace.fix(ws), "it repairs")
	for f, i in ws.frames {
		testing.expect(t, f.id != 0, "every frame has an id")
		for g in ws.frames[:i] do testing.expect(t, g.id != f.id, "ids are unique")
	}
	testing.expect_value(t, ws.frames[3].parent, u32(5))
	testing.expect_value(t, ws.frames[4].parent, u32(0)) // its parent is chained
	testing.expect_value(t, ws.frames[5].parent, u32(0)) // its parent is missing
	testing.expect(t, !workspace.fix(ws), "valid now")
}

// A frame that goes leaves the frames chained to it where they are, each
// heading its own chain. Chaining a frame that heads a chain brings its
// frames along.
@(test)
test_workspace_chain_edits :: proc(t: ^testing.T) {
	ws := workspace.make_workspace("Edits")
	defer workspace.workspace_free(ws)
	a := workspace.frame_add(ws, "A", {0, 0, 100, 50})
	workspace.frame_add(ws, "B", {0, 0, 80, 40}, a)
	x := workspace.frame_add(ws, "X", {800, 0, 100, 50})
	workspace.chain(ws, a, x)
	for f in ws.frames[:2] do testing.expect_value(t, f.parent, x)

	workspace.layout(ws, x)
	before := ws.frames[0].rect
	workspace.tab_remove(ws, 2, 0) // X goes with its only tab
	testing.expect_value(t, len(ws.frames), 2)
	testing.expect_value(t, ws.frames[0].parent, u32(0))
	testing.expect_value(t, ws.frames[1].parent, u32(0))
	testing.expect_value(t, ws.frames[0].rect, before)
}
