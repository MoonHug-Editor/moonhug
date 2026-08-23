package editor

// Editor selection state (Unity model): an ORDERED set plus an implicit
// ACTIVE item — the most recently selected one (last element), which is what
// the inspector shows and single-target actions (rename, gizmo) use. Two
// independent domains: scene objects (Transform_Handles) and project files
// (paths). Multiselect is selection-only for now — no multiedit.
//
// Project selection keeps projectViewData.selectedFile as the ACTIVE path
// (all pre-multiselect code reads it); the set here follows it.

import "core:strings"
import engine "../engine"

// --- Scene selection ---------------------------------------------------------

@(private)
_sel_scene: [dynamic]engine.Transform_Handle // click order; last = active

sel_scene_clear :: proc() {
	clear(&_sel_scene)
}

sel_scene_is :: proc(tH: engine.Transform_Handle) -> bool {
	for h in _sel_scene {
		if h == tH do return true
	}
	return false
}

sel_scene_only :: proc(tH: engine.Transform_Handle) {
	clear(&_sel_scene)
	if tH != _HANDLE_NONE do append(&_sel_scene, tH)
}

// Add if absent, MOVE to the end (= make active) if present.
sel_scene_add :: proc(tH: engine.Transform_Handle) {
	if tH == _HANDLE_NONE do return
	for h, i in _sel_scene {
		if h == tH {
			ordered_remove(&_sel_scene, i)
			break
		}
	}
	append(&_sel_scene, tH)
}

sel_scene_remove :: proc(tH: engine.Transform_Handle) {
	for h, i in _sel_scene {
		if h == tH {
			ordered_remove(&_sel_scene, i)
			return
		}
	}
}

// Cmd/ctrl-click: in → out, out → in (and active).
sel_scene_toggle :: proc(tH: engine.Transform_Handle) {
	if sel_scene_is(tH) {
		sel_scene_remove(tH)
	} else {
		sel_scene_add(tH)
	}
}

// Drop handles whose objects no longer exist (deleted, scene unloaded).
// Views call this once per frame before reading the selection.
sel_scene_prune :: proc() {
	w := engine.ctx_world()
	if w == nil {
		clear(&_sel_scene)
		return
	}
	for i := 0; i < len(_sel_scene); {
		if !engine.pool_valid(&w.transforms, engine.Handle(_sel_scene[i])) {
			ordered_remove(&_sel_scene, i)
			continue
		}
		i += 1
	}
}

sel_scene_active :: proc() -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return _HANDLE_NONE
	// Walk from the back so a stale (deleted) most-recent entry falls through
	// to the previous still-valid one without requiring a prune first.
	for i := len(_sel_scene) - 1; i >= 0; i -= 1 {
		if engine.pool_valid(&w.transforms, engine.Handle(_sel_scene[i])) {
			return _sel_scene[i]
		}
	}
	return _HANDLE_NONE
}

sel_scene_items :: proc() -> []engine.Transform_Handle {
	return _sel_scene[:]
}

sel_scene_count :: proc() -> int {
	return len(_sel_scene)
}

// The selection minus items that have a selected ancestor — what set-wide
// structural actions (delete, duplicate) operate on, so a parent and its
// child being both selected doesn't delete/duplicate the child twice.
// Temp-allocated.
sel_scene_top_level :: proc() -> []engine.Transform_Handle {
	out := make([dynamic]engine.Transform_Handle, 0, len(_sel_scene), context.temp_allocator)
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
	sub_id: engine.Local_ID,
}

@(private)
_sel_proj: [dynamic]Proj_Sel // click order; last = active

sel_proj_clear :: proc() {
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

sel_proj_is_sub :: proc(path: string, sub_id: engine.Local_ID) -> bool {
	for e in _sel_proj {
		if e.sub_id == sub_id && e.path == path do return true
	}
	return false
}

// Select-only. Callers go through _project_set_selected (which keeps
// projectViewData.selectedFile — the active path — in sync).
sel_proj_only :: proc(path: string, sub_id: engine.Local_ID = 0) {
	sel_proj_clear()
	if path != "" do append(&_sel_proj, Proj_Sel{path = strings.clone(path), sub_id = sub_id})
}

// Add if absent, move to the end (= active) if present.
sel_proj_add :: proc(path: string, sub_id: engine.Local_ID = 0) {
	if path == "" do return
	for e, i in _sel_proj {
		if e.path == path && e.sub_id == sub_id {
			ordered_remove(&_sel_proj, i)
			append(&_sel_proj, e) // keep the existing clone
			return
		}
	}
	append(&_sel_proj, Proj_Sel{path = strings.clone(path), sub_id = sub_id})
}

sel_proj_remove :: proc(path: string, sub_id: engine.Local_ID = 0) {
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
	delete(_sel_scene)
	sel_proj_clear()
	delete(_sel_proj)
}
