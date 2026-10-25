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
	id:     string, // owned, unique across providers
	name:   string, // owned
	pan:    [2]f32, // the canvas offset: where its origin sits in the view
	frames: [dynamic]Frame,
}

Frame :: struct {
	rect:   [4]f32,          // x, y, w, h on the canvas
	tabs:   [dynamic]string, // owned window instance keys, in tab order
	active: int,             // the tab showing
}

// Where workspaces live. `list` appends the workspaces it holds now, `save`
// writes `ws` after a change, `create` makes a new empty one (nil when it
// cannot, say with no scene open), `remove` deletes one.
Provider :: struct {
	name:   string,
	list:   proc(out: ^[dynamic]^Workspace),
	save:   proc(ws: ^Workspace),
	create: proc(name: string) -> ^Workspace,
	remove: proc(ws: ^Workspace),
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

// Adds a frame holding the view `key` at `rect`.
frame_add :: proc(ws: ^Workspace, key: string, rect: [4]f32) {
	context.allocator = runtime.default_allocator()
	f := Frame{rect = rect}
	append(&f.tabs, strings.clone(key))
	append(&ws.frames, f)
}

// Removes tab `tab` of frame `frame`, and the frame with its last tab.
tab_remove :: proc(ws: ^Workspace, frame, tab: int) {
	context.allocator = runtime.default_allocator()
	f := &ws.frames[frame]
	delete(f.tabs[tab])
	ordered_remove(&f.tabs, tab)
	if len(f.tabs) == 0 {
		delete(f.tabs)
		ordered_remove(&ws.frames, frame)
		return
	}
	f.active = clamp(f.active, 0, len(f.tabs) - 1)
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
	})
	provider_add({
		name   = "Project",
		list   = proc(out: ^[dynamic]^Workspace) { _store_list(&_project, out) },
		save   = proc(ws: ^Workspace) { _store_save(&_project) },
		create = proc(name: string) -> ^Workspace { return _store_create(&_project, name) },
		remove = proc(ws: ^Workspace) { _store_remove(&_project, ws) },
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
