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

@(private)
_sel_proj: [dynamic]string // owned clones; click order; last = active

sel_proj_clear :: proc() {
	for p in _sel_proj do delete(p)
	clear(&_sel_proj)
}

sel_proj_is :: proc(path: string) -> bool {
	for p in _sel_proj {
		if p == path do return true
	}
	return false
}

// Select-only. Callers go through _project_set_selected (which keeps
// projectViewData.selectedFile — the active path — in sync).
sel_proj_only :: proc(path: string) {
	sel_proj_clear()
	if path != "" do append(&_sel_proj, strings.clone(path))
}

// Add if absent, move to the end (= active) if present.
sel_proj_add :: proc(path: string) {
	if path == "" do return
	for p, i in _sel_proj {
		if p == path {
			ordered_remove(&_sel_proj, i)
			append(&_sel_proj, p) // keep the existing clone
			return
		}
	}
	append(&_sel_proj, strings.clone(path))
}

sel_proj_remove :: proc(path: string) {
	for p, i in _sel_proj {
		if p == path {
			delete(p)
			ordered_remove(&_sel_proj, i)
			return
		}
	}
}

sel_proj_items :: proc() -> []string {
	return _sel_proj[:]
}

sel_proj_count :: proc() -> int {
	return len(_sel_proj)
}

// The most recent still-selected path, for re-pointing the active file after
// a toggle-off ("" when the set is empty).
sel_proj_last :: proc() -> string {
	if len(_sel_proj) == 0 do return ""
	return _sel_proj[len(_sel_proj) - 1]
}

selection_shutdown :: proc() {
	delete(_sel_scene)
	sel_proj_clear()
	delete(_sel_proj)
}
