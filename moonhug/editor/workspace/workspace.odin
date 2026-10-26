package workspace

// Workspaces (docs/core/Views.md): a canvas you pan, holding frames, each a
// group of view tabs at a rectangle. The workspace view draws them
// (editor/workspace_view.odin). This package holds what a workspace is and
// where workspaces come from, and needs no engine, so a plugin can add a
// source of its own.
//
// - A workspace has a unique id, which the workspace view remembers, a name
//   and its frames. A frame names its views by window instance key (`id`,
//   `id/<asset guid>`, `id/<n>`), so a hosted view reopens from it.
// - Frames form chains, one level deep: a frame with a parent sits right of
//   it, under its earlier siblings, and moves with it (layout). Chains keep
//   apart: one that overlaps another moves away.
// - Workspaces come from providers. Each provider holds a list, saves it,
//   makes new ones. User settings and project settings are built in (this
//   file), each in its own file. A provider's list may change: one that keeps
//   workspaces in a scene shows its scene's while that scene is open, so
//   their ids come and go from the workspace view's list.
// - Everything outlives frames, so it lives on the default allocator.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:crypto"
import "core:os"
import "core:strings"

Workspace :: struct {
	id:         string, // owned, unique across providers
	name:       string, // owned
	pan:        [2]f32, // the canvas offset: where its origin sits in the view
	frames:     [dynamic]Frame,
	next_frame: u32,    // the next frame id: ids are never reused, so a new frame takes nothing from a removed one
}

Frame :: struct {
	id:     u32,             // unique in its workspace, never 0
	parent: u32,             // the id of the frame it is chained to, 0 for none
	rect:   [4]f32,          // x, y, w, h on the canvas. A chained frame's x and y follow its parent (layout)
	tabs:   [dynamic]string, // owned window instance keys, in tab order
	active: int,             // the tab showing
}

// Between a frame and the frames chained to it, and between them.
CHAIN_COLUMN_GAP :: f32(30)
CHAIN_ROW_GAP :: f32(20)
// The least space between two chains.
CHAIN_SPACING :: f32(40)

// Where workspaces live. `list` appends the workspaces it holds now, `save`
// writes `ws` after a change, `create` makes a new empty one (nil when it
// cannot, say with no scene open), `remove` deletes one. `detach` lets one
// go without freeing it and `adopt` takes one in, which move_to uses to save
// a workspace somewhere else: nil when the provider cannot.
Provider :: struct {
	name:   string,
	list:   proc(out: ^[dynamic]^Workspace),
	save:   proc(ws: ^Workspace),
	create: proc(name: string) -> ^Workspace,
	remove: proc(ws: ^Workspace),
	detach: proc(ws: ^Workspace),
	adopt:  proc(ws: ^Workspace) -> bool,
}

@(private)
_providers: [dynamic]Provider

// Process-global: never borrows the caller's allocator.
provider_add :: proc(p: Provider) {
	context.allocator = runtime.default_allocator()
	append(&_providers, p)
}

providers :: proc() -> []Provider {
	return _providers[:]
}

// A workspace and the index of the provider that holds it.
Entry :: struct {
	ws:       ^Workspace,
	provider: int,
}

// Every workspace every provider holds now, provider by provider.
all :: proc(allocator := context.temp_allocator) -> []Entry {
	out := make([dynamic]Entry, allocator)
	list := make([dynamic]^Workspace, context.temp_allocator)
	for p, pi in _providers {
		clear(&list)
		if p.list != nil do p.list(&list)
		for ws in list do append(&out, Entry{ws, pi})
	}
	return out[:]
}

// The workspace whose id is `id`, nil while no provider holds it.
find :: proc(id: string) -> (Entry, bool) {
	if id == "" do return {}, false
	for e in all() do if e.ws.id == id do return e, true
	return {}, false
}

// Saves `ws` through the provider that holds it. Call after every change.
changed :: proc(ws: ^Workspace) {
	if e, ok := find(ws.id); ok {
		if p := _providers[e.provider]; p.save != nil do p.save(ws)
	}
}

// Moves the workspace `ws` to the provider `to` (an index into providers),
// keeping its id, name and frames: a Workspace view showing it goes on
// showing it. False when it is there already, or a provider cannot.
move_to :: proc(ws: ^Workspace, to: int) -> bool {
	e, ok := find(ws.id)
	if !ok || to < 0 || to >= len(_providers) || e.provider == to do return false
	from, dst := _providers[e.provider], _providers[to]
	if from.detach == nil || dst.adopt == nil do return false
	from.detach(ws)
	if !dst.adopt(ws) {
		// Back where it was: a workspace never ends up in no provider.
		if from.adopt == nil || !from.adopt(ws) do panic("workspace.move_to: neither provider holds the workspace")
		return false
	}
	return true
}

// Whether the workspace `ws` can move to the provider `to`.
can_move_to :: proc(ws: ^Workspace, to: int) -> bool {
	e, ok := find(ws.id)
	if !ok || to < 0 || to >= len(_providers) || e.provider == to do return false
	return _providers[e.provider].detach != nil && _providers[to].adopt != nil
}

// A new workspace with a fresh id, for a provider's `create`.
make_workspace :: proc(name: string) -> ^Workspace {
	context.allocator = runtime.default_allocator()
	ws := new(Workspace)
	ws.id = new_id()
	ws.name = strings.clone(name)
	return ws
}

new_id :: proc() -> string {
	context.allocator = runtime.default_allocator()
	context.random_generator = crypto.random_generator()
	return uuid.to_string(uuid.generate_v4())
}

// Adds a frame holding the view `key` at `rect`, chained to the frame
// `parent` (an id, 0 for none), and returns its id. A frame chained to a
// chained frame joins that frame's parent: chains are one level deep.
frame_add :: proc(ws: ^Workspace, key: string, rect: [4]f32, parent: u32 = 0) -> u32 {
	context.allocator = runtime.default_allocator()
	f := Frame{id = _next_id(ws), parent = chain_root(ws, parent), rect = rect}
	append(&f.tabs, strings.clone(key))
	append(&ws.frames, f)
	return f.id
}

// Removes tab `tab` of frame `frame`, and the frame with its last tab. The
// frames chained to a removed frame stay where they are, chained to nothing.
tab_remove :: proc(ws: ^Workspace, frame, tab: int) {
	context.allocator = runtime.default_allocator()
	f := &ws.frames[frame]
	delete(f.tabs[tab])
	ordered_remove(&f.tabs, tab)
	if len(f.tabs) == 0 {
		id := f.id
		delete(f.tabs)
		ordered_remove(&ws.frames, frame)
		for &c in ws.frames do if c.parent == id do c.parent = 0
		return
	}
	f.active = clamp(f.active, 0, len(f.tabs) - 1)
}

// The index of the frame whose id is `id`, -1 for none.
frame_index :: proc(ws: ^Workspace, id: u32) -> int {
	if id == 0 do return -1
	for f, i in ws.frames do if f.id == id do return i
	return -1
}

// The id of the frame that heads the chain of the frame `id`: its parent,
// or itself. 0 for 0 or an id no frame has.
chain_root :: proc(ws: ^Workspace, id: u32) -> u32 {
	i := frame_index(ws, id)
	if i < 0 do return 0
	return ws.frames[i].parent if ws.frames[i].parent != 0 else id
}

// Chains the frame `id` to the frame `parent`, or unchains it with 0. The
// frames chained to it come along: chains are one level deep.
chain :: proc(ws: ^Workspace, id: u32, parent: u32) {
	target := chain_root(ws, parent)
	if target == id do return
	for &f in ws.frames {
		if f.id == id || (f.parent == id && target != 0) do f.parent = target
	}
}

// The place of the chained frame `id` among its siblings (the frames chained
// to the same parent, in list order), -1 for a frame chained to nothing.
sibling_index :: proc(ws: ^Workspace, id: u32) -> int {
	i := frame_index(ws, id)
	if i < 0 || ws.frames[i].parent == 0 do return -1
	n := 0
	for g in ws.frames[:i] do if g.parent == ws.frames[i].parent do n += 1
	return n
}

// Moves the chained frame `id` to place `to` among its siblings: the layout
// stacks it there.
sibling_move :: proc(ws: ^Workspace, id: u32, to: int) {
	context.allocator = runtime.default_allocator()
	i := frame_index(ws, id)
	if i < 0 || ws.frames[i].parent == 0 || sibling_index(ws, id) == to do return
	f := ws.frames[i]
	ordered_remove(&ws.frames, i)
	// Before the sibling now at place `to`, or after the last one.
	at, n := -1, 0
	for g, gi in ws.frames {
		if g.parent != f.parent do continue
		if n == to {
			at = gi
			break
		}
		n += 1
		at = gi + 1
	}
	inject_at(&ws.frames, at if at >= 0 else i, f)
}

// Makes the frames valid, whatever a provider loaded: every frame gets a
// unique id, and a parent that is missing, itself, or chained is dropped.
// True when it changed something.
fix :: proc(ws: ^Workspace) -> (changed: bool) {
	for &f, i in ws.frames {
		dup := false
		for g in ws.frames[:i] do if g.id == f.id do dup = true
		if f.id == 0 || dup {
			f.id = _next_id(ws)
			changed = true
		}
	}
	for &f in ws.frames {
		if f.parent == 0 do continue
		p := frame_index(ws, f.parent)
		if p < 0 || f.parent == f.id || ws.frames[p].parent != 0 {
			f.parent = 0
			changed = true
		}
	}
	return
}

// Places the chained frames and keeps chains apart. A chained frame sits
// CHAIN_COLUMN_GAP right of its parent, CHAIN_ROW_GAP under the one before it,
// in list order. Then a chain that comes nearer another than CHAIN_SPACING
// moves away from it, by the shortest way out. The chain of the frame
// `pinned` (an id, 0 for none) stays, the other one moves: the chain being
// dragged or worked in pushes the rest. True when a frame moved.
layout :: proc(ws: ^Workspace, pinned: u32 = 0) -> (moved: bool) {
	for root in ws.frames {
		if root.parent != 0 do continue
		x := root.rect.x + root.rect.z + CHAIN_COLUMN_GAP
		y := root.rect.y
		for &c in ws.frames {
			if c.parent != root.id do continue
			if c.rect.x != x || c.rect.y != y {
				c.rect.x, c.rect.y = x, y
				moved = true
			}
			y += c.rect.w + CHAIN_ROW_GAP
		}
	}

	// Each chain as its root and the box around it (min x, min y, max x, max y).
	Chain :: struct {
		root: u32,
		box:  [4]f32,
	}
	chains := make([dynamic]Chain, context.temp_allocator)
	for f in ws.frames {
		if f.parent != 0 do continue
		append(&chains, Chain{f.id, {f.rect.x, f.rect.y, f.rect.x + f.rect.z, f.rect.y + f.rect.w}})
	}
	for f in ws.frames {
		if f.parent == 0 do continue
		for &c in chains do if c.root == f.parent {
			c.box = {min(c.box.x, f.rect.x), min(c.box.y, f.rect.y), max(c.box.z, f.rect.x + f.rect.z), max(c.box.w, f.rect.y + f.rect.w)}
		}
	}
	keep := chain_root(ws, pinned)
	// Each pass parts every pair that is too near. Moving one chain can bring
	// it near a third, so passes repeat until none moves, a few at most.
	for _ in 0 ..< 32 {
		parted := false
		for i in 0 ..< len(chains) {
			for j in i + 1 ..< len(chains) {
				a, b := chains[i].box, chains[j].box
				g := CHAIN_SPACING
				if !(b.x < a.z + g && a.x < b.z + g && b.y < a.w + g && a.y < b.w + g) do continue
				// The later chain moves, unless it is the pinned one.
				mover, other := j, i
				if chains[j].root == keep do mover, other = i, j
				m, o := chains[mover].box, chains[other].box
				right := o.z + g - m.x
				left := m.z + g - o.x
				down := o.w + g - m.y
				up := m.w + g - o.y
				d := [2]f32{right, 0}
				if left < abs(d.x) + abs(d.y) do d = {-left, 0}
				if down < abs(d.x) + abs(d.y) do d = {0, down}
				if up < abs(d.x) + abs(d.y) do d = {0, -up}
				chains[mover].box += {d.x, d.y, d.x, d.y}
				for &f in ws.frames {
					if f.id == chains[mover].root || f.parent == chains[mover].root {
						f.rect.x += d.x
						f.rect.y += d.y
					}
				}
				parted = true
				moved = true
			}
		}
		if !parted do break
	}
	return
}

@(private = "file")
_next_id :: proc(ws: ^Workspace) -> u32 {
	id := max(ws.next_frame, 1)
	for f in ws.frames do id = max(id, f.id + 1)
	ws.next_frame = id + 1
	return id
}

workspace_free :: proc(ws: ^Workspace) {
	context.allocator = runtime.default_allocator()
	delete(ws.id)
	delete(ws.name)
	for f in ws.frames {
		for k in f.tabs do delete(k)
		delete(f.tabs)
	}
	delete(ws.frames)
	free(ws)
}

// --- File providers (user settings, project settings) -----------------------

// The workspaces one file holds, loaded on first use.
@(private = "file")
_File_Store :: struct {
	path:   string,
	loaded: bool,
	list:   [dynamic]^Workspace,
}

@(private = "file")
_File :: struct {
	workspaces: []Workspace,
}

@(private = "file")
_user := _File_Store{path = "UserSettings/workspaces.json"}

@(private = "file")
_project := _File_Store{path = "ProjectSettings/workspaces.json"}

@(private = "file")
_store_load :: proc(s: ^_File_Store) {
	if s.loaded do return
	s.loaded = true
	context.allocator = runtime.default_allocator()
	bytes, err := os.read_entire_file(s.path, context.temp_allocator)
	if err != nil do return
	file: _File
	if json.unmarshal(bytes, &file) != nil do return
	for ws in file.workspaces {
		p := new(Workspace)
		p^ = ws
		append(&s.list, p)
	}
	delete(file.workspaces)
}

@(private = "file")
_store_save :: proc(s: ^_File_Store) {
	file := _File{workspaces = make([]Workspace, len(s.list), context.temp_allocator)}
	for ws, i in s.list do file.workspaces[i] = ws^
	bytes, err := json.marshal(file, {pretty = true, spec = .JSON}, context.temp_allocator)
	if err != nil do return
	_ = os.write_entire_file(s.path, bytes)
}

@(private = "file")
_store_create :: proc(s: ^_File_Store, name: string) -> ^Workspace {
	_store_load(s)
	context.allocator = runtime.default_allocator()
	ws := make_workspace(name)
	append(&s.list, ws)
	_store_save(s)
	return ws
}

@(private = "file")
_store_remove :: proc(s: ^_File_Store, ws: ^Workspace) {
	for w, i in s.list {
		if w != ws do continue
		ordered_remove(&s.list, i)
		workspace_free(ws)
		_store_save(s)
		return
	}
}

@(private = "file")
_store_detach :: proc(s: ^_File_Store, ws: ^Workspace) {
	for w, i in s.list {
		if w != ws do continue
		ordered_remove(&s.list, i)
		_store_save(s)
		return
	}
}

@(private = "file")
_store_adopt :: proc(s: ^_File_Store, ws: ^Workspace) -> bool {
	_store_load(s)
	context.allocator = runtime.default_allocator()
	append(&s.list, ws)
	_store_save(s)
	return true
}

@(private = "file")
_store_list :: proc(s: ^_File_Store, out: ^[dynamic]^Workspace) {
	_store_load(s)
	for ws in s.list do append(out, ws)
}

@(init, private = "file")
_register_file_providers :: proc "contextless" () {
	context = runtime.default_context()
	provider_add({
		name   = "User",
		list   = proc(out: ^[dynamic]^Workspace) { _store_list(&_user, out) },
		save   = proc(ws: ^Workspace) { _store_save(&_user) },
		create = proc(name: string) -> ^Workspace { return _store_create(&_user, name) },
		remove = proc(ws: ^Workspace) { _store_remove(&_user, ws) },
		detach = proc(ws: ^Workspace) { _store_detach(&_user, ws) },
		adopt  = proc(ws: ^Workspace) -> bool { return _store_adopt(&_user, ws) },
	})
	provider_add({
		name   = "Project",
		list   = proc(out: ^[dynamic]^Workspace) { _store_list(&_project, out) },
		save   = proc(ws: ^Workspace) { _store_save(&_project) },
		create = proc(name: string) -> ^Workspace { return _store_create(&_project, name) },
		remove = proc(ws: ^Workspace) { _store_remove(&_project, ws) },
		detach = proc(ws: ^Workspace) { _store_detach(&_project, ws) },
		adopt  = proc(ws: ^Workspace) -> bool { return _store_adopt(&_project, ws) },
	})
}

// Frees what the built-in providers loaded. Once, at editor shutdown.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for s in ([]^_File_Store{&_user, &_project}) {
		for ws in s.list do workspace_free(ws)
		delete(s.list)
		s^ = {path = s.path}
	}
	for k, s in _views.by_key {
		delete(k)
		delete(s.workspace)
		free(s)
	}
	delete(_views.by_key)
	_views = {}
}

// --- What each Workspace view remembers ------------------------------------

// What a Workspace view copy remembers between sessions, by its key
// ("workspace", "workspace/2"). In the user's settings. Zero is the default.
View_Settings :: struct {
	workspace: string, // owned, the id of the workspace it shows
	minimap:   Minimap,
}

// The mini-map's place in the view: attached to a corner or a side of the
// canvas, moved from there by `offset`, at `size` (0 is the default size).
Minimap :: struct {
	hidden: bool,
	anchor: Anchor,
	offset: [2]f32,
	size:   [2]f32,
}

Anchor :: enum {
	Top_Right,
	Top,
	Top_Left,
	Left,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	Right,
}

@(private = "file")
_views: struct {
	loaded: bool,
	by_key: map[string]^View_Settings, // owned keys and settings
}

@(private = "file")
_VIEWS_PATH :: "UserSettings/workspace_views.json"

// The settings of the Workspace view `view`, made on first use. Call
// view_settings_save after changing them.
view_settings :: proc(view: string) -> ^View_Settings {
	_views_load()
	if s, has := _views.by_key[view]; has do return s
	context.allocator = runtime.default_allocator()
	s := new(View_Settings)
	_views.by_key[strings.clone(view)] = s
	return s
}

view_settings_save :: proc() {
	out := make(map[string]View_Settings, len(_views.by_key), context.temp_allocator)
	for k, s in _views.by_key do out[k] = s^
	bytes, err := json.marshal(out, {pretty = true, spec = .JSON, sort_maps_by_key = true}, context.temp_allocator)
	if err == nil do _ = os.write_entire_file(_VIEWS_PATH, bytes)
}

// The id of the workspace the view `view` shows, "" for none.
view_selection :: proc(view: string) -> string {
	return view_settings(view).workspace
}

view_select :: proc(view: string, id: string) {
	s := view_settings(view)
	if s.workspace == id do return
	delete(s.workspace, runtime.default_allocator())
	s.workspace = strings.clone(id, runtime.default_allocator())
	view_settings_save()
}

@(private = "file")
_views_load :: proc() {
	if _views.loaded do return
	_views.loaded = true
	context.allocator = runtime.default_allocator()
	bytes, err := os.read_entire_file(_VIEWS_PATH, context.temp_allocator)
	if err != nil do return
	file: map[string]View_Settings
	defer delete(file)
	if json.unmarshal(bytes, &file) != nil do return
	for k, s in file {
		p := new(View_Settings)
		p^ = s
		_views.by_key[k] = p
	}
}
