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
