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
// - Frames form trees of any depth: a frame with a parent sits right of it,
//   under its earlier siblings and their children, and moves with it
//   (layout). Trees keep apart: one that overlaps another moves away.
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
import "moonhug:libs/log"

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

// Between a frame and the frames chained to it, and between their subtrees.
CHAIN_COLUMN_GAP :: f32(30)
CHAIN_ROW_GAP :: f32(20)
// The least space between two trees.
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
// `parent` (an id, 0 for none, any frame), and returns its id. A parent no
// frame has is none.
frame_add :: proc(ws: ^Workspace, key: string, rect: [4]f32, parent: u32 = 0) -> u32 {
	context.allocator = runtime.default_allocator()
	f := Frame{id = _next_id(ws), parent = parent if frame_index(ws, parent) >= 0 else 0, rect = rect}
	append(&f.tabs, strings.clone(key))
	append(&ws.frames, f)
	return f.id
}

// Removes tab `tab` of frame `frame`, and the frame with its last tab. The
// frames chained to a removed frame take its place under its parent
// (_frame_remove).
tab_remove :: proc(ws: ^Workspace, frame, tab: int) {
	context.allocator = runtime.default_allocator()
	f := &ws.frames[frame]
	delete(f.tabs[tab])
	ordered_remove(&f.tabs, tab)
	if len(f.tabs) == 0 {
		_frame_remove(ws, frame)
		return
	}
	// The same tab stays active when one before it goes.
	if tab < f.active do f.active -= 1
	f.active = clamp(f.active, 0, len(f.tabs) - 1)
}

// Removes the frame at index `i`. Its children take its place: chained to
// its parent, at its place among its siblings, in their own order. The
// children of a removed root head their own trees.
@(private = "file")
_frame_remove :: proc(ws: ^Workspace, i: int) {
	context.allocator = runtime.default_allocator()
	id, parent := ws.frames[i].id, ws.frames[i].parent
	for k in ws.frames[i].tabs do delete(k)
	delete(ws.frames[i].tabs)
	ordered_remove(&ws.frames, i)
	// Sibling order is list order, so the children move to where the frame
	// was in the list.
	kids := make([dynamic]Frame, context.temp_allocator)
	at := i
	for k := 0; k < len(ws.frames); {
		if ws.frames[k].parent != id {
			k += 1
			continue
		}
		if k < at do at -= 1
		append(&kids, ws.frames[k])
		ordered_remove(&ws.frames, k)
	}
	for &c, n in kids {
		c.parent = parent
		inject_at(&ws.frames, at + n, c)
	}
}

// The index of the frame whose id is `id`, -1 for none.
frame_index :: proc(ws: ^Workspace, id: u32) -> int {
	if id == 0 do return -1
	for f, i in ws.frames do if f.id == id do return i
	return -1
}

// The id of the frame that heads the tree of the frame `id`: its topmost
// ancestor, or itself. 0 for 0 or an id no frame has. A parent no frame has
// ends the walk.
chain_root :: proc(ws: ^Workspace, id: u32) -> u32 {
	i := frame_index(ws, id)
	if i < 0 do return 0
	for _ in 0 ..= len(ws.frames) {
		p := frame_index(ws, ws.frames[i].parent)
		if p < 0 do return ws.frames[i].id
		i = p
	}
	panic("workspace.chain_root: the frames' parents form a cycle")
}

// Whether the frame `ancestor` is above the frame `id` in its tree: its
// parent, its parent's parent, and so on. A frame is not its own ancestor.
is_ancestor :: proc(ws: ^Workspace, ancestor, id: u32) -> bool {
	if ancestor == 0 do return false
	i := frame_index(ws, id)
	if i < 0 do return false
	for _ in 0 ..= len(ws.frames) {
		p := ws.frames[i].parent
		if p == ancestor do return true
		i = frame_index(ws, p)
		if i < 0 do return false
	}
	panic("workspace.is_ancestor: the frames' parents form a cycle")
}

// The frame `id` and every frame below it, a parent before its children,
// siblings in their order. Empty for an id no frame has.
subtree :: proc(ws: ^Workspace, id: u32, allocator := context.temp_allocator) -> []u32 {
	out := make([dynamic]u32, allocator)
	if frame_index(ws, id) < 0 do return out[:]
	append(&out, id)
	// Each frame's children go right after it: `out` grows as it is read.
	for at := 0; at < len(out); at += 1 {
		kids := 0
		for f in ws.frames do if f.parent == out[at] {
			inject_at(&out, at + 1 + kids, f.id)
			kids += 1
		}
		if len(out) > len(ws.frames) do panic("workspace.subtree: the frames' parents form a cycle")
	}
	return out[:]
}

// Chains the frame `id` to the frame `parent`, or unchains it with 0. The
// frames below it come along. Refused, with no change, when `parent` is the
// frame itself, below it, or no frame.
chain :: proc(ws: ^Workspace, id: u32, parent: u32) {
	i := frame_index(ws, id)
	if i < 0 do return
	if parent != 0 && (parent == id || frame_index(ws, parent) < 0 || is_ancestor(ws, id, parent)) do return
	ws.frames[i].parent = parent
	// The frame and its subtree go to the end of the list, so a newly chained
	// frame is its parent's last child (siblings are in list order).
	ids := subtree(ws, id, context.temp_allocator)
	moved := make([dynamic]Frame, 0, len(ids), context.temp_allocator)
	for sid in ids {
		j := frame_index(ws, sid)
		append(&moved, ws.frames[j])
		ordered_remove(&ws.frames, j)
	}
	for f in moved do append(&ws.frames, f)
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

// Makes the frames valid, whatever a provider loaded: a frame with no tabs
// goes (its children take its place, _frame_remove), every frame gets a
// unique id, a parent that is missing or itself is dropped, and a frame
// whose parents lead back to it heads its own tree, which breaks the cycle.
// True when it changed something.
fix :: proc(ws: ^Workspace) -> (changed: bool) {
	for {
		empty := -1
		for f, i in ws.frames do if len(f.tabs) == 0 {
			empty = i
			break
		}
		if empty < 0 do break
		_frame_remove(ws, empty)
		changed = true
	}
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
		if f.parent == f.id || frame_index(ws, f.parent) < 0 {
			f.parent = 0
			changed = true
		}
	}
	// Every parent exists now, so a walk up either ends at a root or goes
	// round a cycle, which comes back to each of its frames within
	// len(frames) steps. The first frame of a cycle found heads a tree.
	for &f in ws.frames {
		p := f.parent
		for _ in 0 ..< len(ws.frames) {
			if p == 0 do break
			if p == f.id {
				f.parent = 0
				changed = true
				break
			}
			p = ws.frames[frame_index(ws, p)].parent
		}
	}
	return
}

// Places the chained frames and keeps trees apart. A frame's children sit
// CHAIN_COLUMN_GAP right of it, stacked down from its top in sibling order.
// Each child takes the height of its subtree (its own height, or its
// children's stacked height when that is more), and CHAIN_ROW_GAP parts one
// from the next. Then a tree that comes nearer another than CHAIN_SPACING
// moves away from it, by the shortest way, its box being the bounds of all
// its frames. The tree of the frame `pinned` (an id, 0 for none) stays, the
// other one moves: the tree being dragged or worked in pushes the rest. True
// when a frame moved.
layout :: proc(ws: ^Workspace, pinned: u32 = 0) -> (moved: bool) {
	// Each tree as its root, its frames and the box around them (min x,
	// min y, max x, max y). A frame whose parent no frame has heads a tree.
	Tree :: struct {
		root:   u32,
		frames: []u32,
		box:    [4]f32,
	}
	trees := make([dynamic]Tree, context.temp_allocator)
	for i in 0 ..< len(ws.frames) {
		if frame_index(ws, ws.frames[i].parent) >= 0 do continue
		root := ws.frames[i].id
		_place_children(ws, root, &moved)
		t := Tree{root = root, frames = subtree(ws, root), box = {max(f32), max(f32), min(f32), min(f32)}}
		for id in t.frames {
			r := ws.frames[frame_index(ws, id)].rect
			t.box = {min(t.box.x, r.x), min(t.box.y, r.y), max(t.box.z, r.x + r.z), max(t.box.w, r.y + r.w)}
		}
		append(&trees, t)
	}

	keep := chain_root(ws, pinned)
	// Each pass parts every pair that is too near. Moving one tree can bring
	// it near a third, so passes repeat until none moves, a few at most.
	for _ in 0 ..< 32 {
		parted := false
		for i in 0 ..< len(trees) {
			for j in i + 1 ..< len(trees) {
				a, b := trees[i].box, trees[j].box
				g := CHAIN_SPACING
				if !(b.x < a.z + g && a.x < b.z + g && b.y < a.w + g && a.y < b.w + g) do continue
				// The later tree moves, unless it is the pinned one.
				mover, other := j, i
				if trees[j].root == keep do mover, other = i, j
				m, o := trees[mover].box, trees[other].box
				right := o.z + g - m.x
				left := m.z + g - o.x
				down := o.w + g - m.y
				up := m.w + g - o.y
				d := [2]f32{right, 0}
				if left < abs(d.x) + abs(d.y) do d = {-left, 0}
				if down < abs(d.x) + abs(d.y) do d = {0, down}
				if up < abs(d.x) + abs(d.y) do d = {0, -up}
				trees[mover].box += {d.x, d.y, d.x, d.y}
				for id in trees[mover].frames {
					f := &ws.frames[frame_index(ws, id)]
					f.rect.x += d.x
					f.rect.y += d.y
				}
				parted = true
				moved = true
			}
		}
		if !parted do break
	}
	return
}

// Places the children of the frame `id`, and theirs below them (layout).
@(private = "file")
_place_children :: proc(ws: ^Workspace, id: u32, moved: ^bool) {
	r := ws.frames[frame_index(ws, id)].rect
	x := r.x + r.z + CHAIN_COLUMN_GAP
	y := r.y
	for k in 0 ..< len(ws.frames) {
		c := &ws.frames[k]
		if c.parent != id do continue
		if c.rect.x != x || c.rect.y != y {
			c.rect.x, c.rect.y = x, y
			moved^ = true
		}
		_place_children(ws, c.id, moved)
		y += _subtree_height(ws, c.id) + CHAIN_ROW_GAP
	}
}

// The height the frame `id` takes in its parent's column: its own, or its
// children's stacked height when that is more.
@(private = "file")
_subtree_height :: proc(ws: ^Workspace, id: u32) -> f32 {
	stacked, n := f32(0), 0
	for f in ws.frames {
		if f.parent != id do continue
		if n > 0 do stacked += CHAIN_ROW_GAP
		stacked += _subtree_height(ws, f.id)
		n += 1
	}
	return max(ws.frames[frame_index(ws, id)].rect.w, stacked)
}

@(private = "file")
_next_id :: proc(ws: ^Workspace) -> u32 {
	id := max(ws.next_frame, 1)
	for f in ws.frames do id = max(id, f.id + 1)
	ws.next_frame = id + 1
	return id
}

workspace_free :: proc(ws: ^Workspace) {
	_workspace_free_fields(ws)
	free(ws, runtime.default_allocator())
}

// What a workspace owns, without the workspace itself.
@(private = "file")
_workspace_free_fields :: proc(ws: ^Workspace) {
	context.allocator = runtime.default_allocator()
	delete(ws.id)
	delete(ws.name)
	for f in ws.frames {
		for k in f.tabs do delete(k)
		delete(f.tabs)
	}
	delete(ws.frames)
}

// --- File providers (user settings, project settings) -----------------------

// The workspaces one file holds, loaded on first use. A file that does not
// parse marks the store broken: it shows no workspaces and is never written,
// so the file stays as it is for the user to repair.
File_Store :: struct {
	path:    string,
	loaded:  bool,
	broken:  bool, // the file did not read or parse: saving is refused
	refused: bool, // a refused save was logged, so the next ones stay quiet
	list:    [dynamic]^Workspace,
}

@(private = "file")
_File :: struct {
	workspaces: []Workspace,
}

@(private = "file")
_user := File_Store{path = "UserSettings/workspaces.json"}

@(private = "file")
_project := File_Store{path = "ProjectSettings/workspaces.json"}

// Loads the store's file once. A missing file is an empty store.
file_store_load :: proc(s: ^File_Store) {
	if s.loaded do return
	s.loaded = true
	context.allocator = runtime.default_allocator()
	if !os.exists(s.path) do return
	bytes, err := os.read_entire_file(s.path, context.temp_allocator)
	if err != nil {
		log.errorf("workspaces: cannot read %s (%v), its workspaces are not shown and it is not written", s.path, err)
		s.broken = true
		return
	}
	// json.unmarshal loops forever on some truncated files: they are
	// checked first.
	if !json.is_valid(bytes) {
		log.errorf("workspaces: %s does not parse, its workspaces are not shown and it is not written until it is repaired", s.path)
		s.broken = true
		return
	}
	file: _File
	if uerr := json.unmarshal(bytes, &file); uerr != nil {
		log.errorf("workspaces: %s does not parse (%v), its workspaces are not shown and it is not written until it is repaired", s.path, uerr)
		s.broken = true
		for &ws in file.workspaces do _workspace_free_fields(&ws)
		delete(file.workspaces)
		return
	}
	for ws in file.workspaces {
		p := new(Workspace)
		p^ = ws
		append(&s.list, p)
	}
	delete(file.workspaces)
}

// Writes the store's workspaces to its file. False when it did not: the
// store is broken, or the write failed.
file_store_save :: proc(s: ^File_Store) -> bool {
	if s.broken {
		if !s.refused do log.errorf("workspaces: %s did not load, so it is not written: workspace changes are not saved", s.path)
		s.refused = true
		return false
	}
	file := _File{workspaces = make([]Workspace, len(s.list), context.temp_allocator)}
	for ws, i in s.list do file.workspaces[i] = ws^
	bytes, err := json.marshal(file, {pretty = true, spec = .JSON}, context.temp_allocator)
	if err != nil {
		log.errorf("workspaces: cannot encode %s (%v)", s.path, err)
		return false
	}
	if werr := os.write_entire_file(s.path, bytes); werr != nil {
		log.errorf("workspaces: cannot write %s (%v)", s.path, werr)
		return false
	}
	return true
}

// Frees what the store loaded. It loads again on next use.
file_store_free :: proc(s: ^File_Store) {
	context.allocator = runtime.default_allocator()
	for ws in s.list do workspace_free(ws)
	delete(s.list)
	s^ = {path = s.path}
}

@(private = "file")
_store_create :: proc(s: ^File_Store, name: string) -> ^Workspace {
	file_store_load(s)
	if s.broken do return nil
	context.allocator = runtime.default_allocator()
	ws := make_workspace(name)
	append(&s.list, ws)
	file_store_save(s)
	return ws
}

@(private = "file")
_store_remove :: proc(s: ^File_Store, ws: ^Workspace) {
	for w, i in s.list {
		if w != ws do continue
		ordered_remove(&s.list, i)
		workspace_free(ws)
		file_store_save(s)
		return
	}
}

@(private = "file")
_store_detach :: proc(s: ^File_Store, ws: ^Workspace) {
	for w, i in s.list {
		if w != ws do continue
		ordered_remove(&s.list, i)
		file_store_save(s)
		return
	}
}

@(private = "file")
_store_adopt :: proc(s: ^File_Store, ws: ^Workspace) -> bool {
	file_store_load(s)
	if s.broken do return false
	context.allocator = runtime.default_allocator()
	append(&s.list, ws)
	file_store_save(s)
	return true
}

@(private = "file")
_store_list :: proc(s: ^File_Store, out: ^[dynamic]^Workspace) {
	file_store_load(s)
	for ws in s.list do append(out, ws)
}

@(init, private = "file")
_register_file_providers :: proc "contextless" () {
	context = runtime.default_context()
	provider_add({
		name   = "User",
		list   = proc(out: ^[dynamic]^Workspace) { _store_list(&_user, out) },
		save   = proc(ws: ^Workspace) { file_store_save(&_user) },
		create = proc(name: string) -> ^Workspace { return _store_create(&_user, name) },
		remove = proc(ws: ^Workspace) { _store_remove(&_user, ws) },
		detach = proc(ws: ^Workspace) { _store_detach(&_user, ws) },
		adopt  = proc(ws: ^Workspace) -> bool { return _store_adopt(&_user, ws) },
	})
	provider_add({
		name   = "Project",
		list   = proc(out: ^[dynamic]^Workspace) { _store_list(&_project, out) },
		save   = proc(ws: ^Workspace) { file_store_save(&_project) },
		create = proc(name: string) -> ^Workspace { return _store_create(&_project, name) },
		remove = proc(ws: ^Workspace) { _store_remove(&_project, ws) },
		detach = proc(ws: ^Workspace) { _store_detach(&_project, ws) },
		adopt  = proc(ws: ^Workspace) -> bool { return _store_adopt(&_project, ws) },
	})
}

// Frees what the built-in providers loaded. Once, at editor shutdown.
shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	file_store_free(&_user)
	file_store_free(&_project)
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
	if !json.is_valid(bytes) do return // json.unmarshal loops forever on some truncated files
	file: map[string]View_Settings
	defer delete(file)
	if json.unmarshal(bytes, &file) != nil do return
	for k, s in file {
		p := new(View_Settings)
		p^ = s
		_views.by_key[k] = p
	}
}
