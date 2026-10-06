package editor

// Editor selection state (Unity model): an ORDERED set plus an implicit
// ACTIVE item — the most recently selected one (last element), which is what
// the inspector shows and single-target actions (rename, gizmo) use.
//
// ONE selection for the whole editor, held in two sets because scene objects
// (Transform_Handles) and project files (paths) are addressed differently.
// Selecting in one set deselects the other (_sel_take_scene,
// _sel_take_project), so the Edit menu always has one thing to act on and
// the history always names one thing. Clearing one set leaves the other.
//
// The two inspectors keep what they last showed when the selection moves to
// the other set. The Project Inspector does that on its own (it loads a file
// and holds it). The Inspector reads sel_scene_inspected, which falls back to
// the objects the project selection took over (_sel_scene_last).
//
// Project selection keeps projectViewData.selectedFile as the ACTIVE path
// (all pre-multiselect code reads it); the set here follows it.
//
// All of it is editor-wide state that outlives the call that changes it, so
// every proc that grows or frees it pins the default allocator. A caller's
// allocator (a test's tracking allocator, a temp allocator) would otherwise
// own part of it, and the next free under another allocator corrupts the heap.

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import core "moonhug:host/core"
import "moonhug:editor/inspector"
import "subassets"

// --- Scene selection ---------------------------------------------------------

@(private)
_sel_scene: [dynamic]core.Transform_Handle // click order; last = active

// The scene selection as it was when the project selection took over: what
// the Inspector keeps showing. Empty while the scene set is live.
@(private)
_sel_scene_last: [dynamic]core.Transform_Handle

// An explicit clear (Escape, a click on empty space, a delete) empties the
// Inspector too.
sel_scene_clear :: proc() {
	context.allocator = runtime.default_allocator()
	clear(&_sel_scene)
	clear(&_sel_scene_last)
}

// Selecting a scene object deselects every project item.
@(private = "file")
_sel_take_scene :: proc() {
	context.allocator = runtime.default_allocator()
	clear(&_sel_scene_last)
	if len(_sel_proj) > 0 || projectViewData.selectedFile != "" {
		sel_proj_clear()
		_project_set_active("")
	}
}

// Selecting a project item deselects every scene object, which the Inspector
// keeps showing.
@(private = "file")
_sel_take_project :: proc() {
	context.allocator = runtime.default_allocator()
	if len(_sel_scene) == 0 do return
	clear(&_sel_scene_last)
	append(&_sel_scene_last, .._sel_scene[:])
	clear(&_sel_scene)
}

// True when the selection lives in the project set: what the Edit menu acts on.
sel_in_project :: proc() -> bool {
	return len(_sel_scene) == 0 && len(_sel_proj) > 0
}

// The objects the Inspector shows: the scene selection, or, while the
// project holds the selection, the objects it took over.
sel_scene_inspected :: proc() -> []core.Transform_Handle {
	if len(_sel_scene) > 0 do return _sel_scene[:]
	return _sel_scene_last[:]
}

sel_scene_inspected_active :: proc() -> core.Transform_Handle {
	items := sel_scene_inspected()
	for i := len(items) - 1; i >= 0; i -= 1 {
		if _object_alive(items[i]) do return items[i]
	}
	return _HANDLE_NONE
}

// Undo restore sets both sets and the Inspector's kept objects exactly as
// recorded (undo.Selection_State), with no cross-set deselect.
@(private)
_sel_restore_begin :: proc() {
	context.allocator = runtime.default_allocator()
	clear(&_sel_scene_last)
	clear(&_sel_scene)
	sel_proj_clear()
}

@(private)
_sel_restore_kept :: proc(tH: core.Transform_Handle) {
	context.allocator = runtime.default_allocator()
	if tH == _HANDLE_NONE do return
	for h in _sel_scene_last do if h == tH do return
	append(&_sel_scene_last, tH)
}

@(private)
_sel_restore_scene :: proc(tH: core.Transform_Handle) {
	context.allocator = runtime.default_allocator()
	if tH == _HANDLE_NONE || sel_scene_is(tH) do return
	append(&_sel_scene, tH)
}

@(private)
_sel_restore_proj :: proc(path: string, sub_id: core.Local_ID) {
	context.allocator = runtime.default_allocator()
	if path == "" do return
	append(&_sel_proj, Proj_Sel{path = strings.clone(path), sub_id = sub_id})
}

sel_scene_is :: proc(tH: core.Transform_Handle) -> bool {
	for h in _sel_scene {
		if h == tH do return true
	}
	return false
}

sel_scene_only :: proc(tH: core.Transform_Handle) {
	context.allocator = runtime.default_allocator()
	clear(&_sel_scene)
	if tH == _HANDLE_NONE {
		clear(&_sel_scene_last)
		return
	}
	_sel_take_scene()
	append(&_sel_scene, tH)
}

// Add if absent, MOVE to the end (= make active) if present.
sel_scene_add :: proc(tH: core.Transform_Handle) {
	context.allocator = runtime.default_allocator()
	if tH == _HANDLE_NONE do return
	_sel_take_scene()
	for h, i in _sel_scene {
		if h == tH {
			ordered_remove(&_sel_scene, i)
			break
		}
	}
	append(&_sel_scene, tH)
}

sel_scene_remove :: proc(tH: core.Transform_Handle) {
	context.allocator = runtime.default_allocator()
	for h, i in _sel_scene {
		if h == tH {
			ordered_remove(&_sel_scene, i)
			return
		}
	}
}

// Cmd/ctrl-click: in → out, out → in (and active).
sel_scene_toggle :: proc(tH: core.Transform_Handle) {
	if sel_scene_is(tH) {
		sel_scene_remove(tH)
	} else {
		sel_scene_add(tH)
	}
}

// Drop handles whose objects no longer exist (deleted, scene unloaded).
// Views call this once per frame before reading the selection.
sel_scene_prune :: proc() {
	context.allocator = runtime.default_allocator()
	for i := 0; i < len(_sel_scene); {
		if !_object_alive(_sel_scene[i]) {
			ordered_remove(&_sel_scene, i)
			continue
		}
		i += 1
	}
	for i := 0; i < len(_sel_scene_last); {
		if !_object_alive(_sel_scene_last[i]) {
			ordered_remove(&_sel_scene_last, i)
			continue
		}
		i += 1
	}
}

sel_scene_active :: proc() -> core.Transform_Handle {
	// Walk from the back so a stale (deleted) most-recent entry falls through
	// to the previous still-valid one without requiring a prune first.
	for i := len(_sel_scene) - 1; i >= 0; i -= 1 {
		if _object_alive(_sel_scene[i]) {
			return _sel_scene[i]
		}
	}
	return _HANDLE_NONE
}

sel_scene_items :: proc() -> []core.Transform_Handle {
	return _sel_scene[:]
}

sel_scene_count :: proc() -> int {
	return len(_sel_scene)
}

// The selection minus items that have a selected ancestor — what set-wide
// structural actions (delete, duplicate) operate on, so a parent and its
// child being both selected doesn't delete/duplicate the child twice.
// Temp-allocated.
sel_scene_top_level :: proc() -> []core.Transform_Handle {
	out := make([dynamic]core.Transform_Handle, 0, len(_sel_scene), context.temp_allocator)
	outer: for h in _sel_scene {
		for other in _sel_scene {
			if other != h && _is_ancestor(other, h) do continue outer
		}
		append(&out, h)
	}
	return out[:]
}

// --- Project selection --------------------------------------------------------

// One selected project item: the asset (sub_id 0) or one of its sub-assets
// (a sprite slice — sub_id is the slice's persistent id). Undo snapshots
// the pair as PPtr{guid, sub_id}.
Proj_Sel :: struct {
	path:   string, // owned clone
	sub_id: core.Local_ID,
}

@(private)
_sel_proj: [dynamic]Proj_Sel // click order; last = active

sel_proj_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for e in _sel_proj do delete(e.path)
	clear(&_sel_proj)
}

// The asset row's selected state — a selected SUB-asset does not light the
// asset's own row.
sel_proj_is :: proc(path: string) -> bool {
	for e in _sel_proj {
		if e.sub_id == 0 && e.path == path do return true
	}
	return false
}

sel_proj_is_sub :: proc(path: string, sub_id: core.Local_ID) -> bool {
	for e in _sel_proj {
		if e.sub_id == sub_id && e.path == path do return true
	}
	return false
}

// Select-only. Callers go through _project_set_selected (which keeps
// projectViewData.selectedFile — the active path — in sync).
sel_proj_only :: proc(path: string, sub_id: core.Local_ID = 0) {
	context.allocator = runtime.default_allocator()
	sel_proj_clear()
	if path == "" do return
	_sel_take_project()
	append(&_sel_proj, Proj_Sel{path = strings.clone(path), sub_id = sub_id})
}

// Add if absent, move to the end (= active) if present.
sel_proj_add :: proc(path: string, sub_id: core.Local_ID = 0) {
	context.allocator = runtime.default_allocator()
	if path == "" do return
	_sel_take_project()
	for e, i in _sel_proj {
		if e.path == path && e.sub_id == sub_id {
			ordered_remove(&_sel_proj, i)
			append(&_sel_proj, e) // keep the existing clone
			return
		}
	}
	append(&_sel_proj, Proj_Sel{path = strings.clone(path), sub_id = sub_id})
}

sel_proj_remove :: proc(path: string, sub_id: core.Local_ID = 0) {
	context.allocator = runtime.default_allocator()
	for e, i in _sel_proj {
		if e.path == path && e.sub_id == sub_id {
			delete(e.path)
			ordered_remove(&_sel_proj, i)
			return
		}
	}
}

// ASSET paths only (sub_id 0) — what file operations (delete, cut, context
// menu) act on; sub-assets are not files. Temp-allocated.
sel_proj_items :: proc() -> []string {
	out := make([dynamic]string, 0, len(_sel_proj), context.temp_allocator)
	for e in _sel_proj {
		if e.sub_id == 0 do append(&out, e.path)
	}
	return out[:]
}

// The full selection, sub-assets included (undo capture, views).
sel_proj_entries :: proc() -> []Proj_Sel {
	return _sel_proj[:]
}

// The active selection's sub-asset id for `path`, 0 when the active entry is
// another asset, the asset itself, or a sub-asset its provider no longer
// lists. Installed as inspector.selected_sub.
sel_proj_active_sub :: proc(path: string) -> core.Local_ID {
	if len(_sel_proj) == 0 do return 0
	active := _sel_proj[len(_sel_proj) - 1]
	if active.sub_id == 0 || active.path != path do return 0
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	provider, ok := subassets.find(ext)
	if !ok do return 0
	for s in provider.list(path, context.temp_allocator) {
		if s.id == active.sub_id do return s.id
	}
	return 0
}

sel_proj_count :: proc() -> int {
	return len(_sel_proj)
}

// The most recent still-selected path, for re-pointing the active file after
// a toggle-off ("" when the set is empty).
sel_proj_last :: proc() -> string {
	if len(_sel_proj) == 0 do return ""
	return _sel_proj[len(_sel_proj) - 1].path
}

selection_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	delete(_sel_scene)
	delete(_sel_scene_last)
	sel_proj_clear()
	delete(_sel_proj)
}

_HANDLE_NONE :: core.Transform_Handle{}

// `potential_ancestor` is a strict ancestor of `node`, walking the object
// provider's parents.
_is_ancestor :: proc(potential_ancestor: core.Transform_Handle, node: core.Transform_Handle) -> bool {
	current, ok := inspector.object_parent(node)
	for ok {
		if current == potential_ancestor do return true
		current, ok = inspector.object_parent(current)
	}
	return false
}

// The object behind a selected handle still exists (the object provider knows
// its owner). False for every handle when no provider is installed.
_object_alive :: proc(tH: core.Transform_Handle) -> bool {
	_, ok := inspector.object_owner_of(core.Handle(tH))
	return ok
}
