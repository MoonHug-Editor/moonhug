package editor

// Selection changes as undo steps (Unity model): a per-frame tracker diffs
// the selection against a baseline and pushes one Selection_Command per
// changed frame — a click, a shift-range, an Escape-clear each become one
// "Select ..." entry.
//
// A frame where an operation landed on the stack (a create, a paste) and the
// selection changed attaches the change to THAT entry
// (undo.amend_top_selection), so one undo takes back both the operation and
// what it selected. A frame where the stack was otherwise disturbed (undo,
// redo, purge on scene navigation) only re-baselines: that change is the
// restore itself.
//
// The undo package can't import this package, so capture/apply are installed
// as hooks (selection_undo_install, called next to undo.install in main).

import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import engine "../engine"
import "undo"

@(private="file")
_sel_undo_baseline: undo.Selection_State

@(private="file")
_sel_undo_baseline_valid: bool

selection_undo_install :: proc() {
	undo.set_selection_hooks(selection_capture_state, selection_apply_state)
}

selection_undo_shutdown :: proc() {
	undo.selection_state_destroy(&_sel_undo_baseline)
	_sel_undo_baseline_valid = false
}

// Snapshot of both selection domains in recreate-robust form: scene items as
// (scene ref, local_id) — a handle dies with its object, the local_id
// re-resolves after undo restores it — and project items as path clones.
selection_capture_state :: proc() -> undo.Selection_State {
	w := engine.ctx_world()
	as_items :: proc(w: ^engine.World, handles: []engine.Transform_Handle) -> []undo.Selection_Scene_Item {
		items := make([dynamic]undo.Selection_Scene_Item)
		if w == nil do return items[:]
		for h in handles {
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil do continue
			append(&items, undo.Selection_Scene_Item{
				scene    = undo.scene_ref(t.scene),
				local_id = t.local_id,
			})
		}
		return items[:]
	}
	items := as_items(w, sel_scene_items())
	// The Inspector's kept objects, only meaningful while the project holds
	// the selection (sel_scene_inspected falls back to them then).
	kept: []undo.Selection_Scene_Item
	if sel_in_project() do kept = as_items(w, sel_scene_inspected())
	// Project items as PPtr{guid, sub_id} — the guid survives renames, sub_id
	// carries a selected sub-asset (a sprite slice).
	proj := make([dynamic]engine.PPtr)
	for e in sel_proj_entries() {
		if guid, ok := engine.asset_db_get_guid(e.path); ok {
			append(&proj, engine.PPtr{guid = engine.Asset_GUID(guid), local_id = e.sub_id})
		}
	}
	return undo.Selection_State{scene = items, proj = proj[:], kept = kept}
}

selection_apply_state :: proc(state: undo.Selection_State) {
	_sel_restore_begin()
	// What the Inspector kept, resolved the same way as the selection. Dead
	// ones (deleted since) are simply not kept.
	if len(state.scene) == 0 && len(state.proj) > 0 {
		for it in state.kept {
			sc := undo.resolve_scene(it.scene)
			if sc == nil do continue
			if tH, ok := engine.scene_find_selectable_transform_local_id(sc, it.local_id); ok do _sel_restore_kept(tH)
		}
	}
	restored_scene := false
	for it in state.scene {
		sc := undo.resolve_scene(it.scene)
		if sc == nil do continue
		tH, ok := engine.scene_find_selectable_transform_local_id(sc, it.local_id)
		if !ok do continue
		_sel_restore_scene(tH)
		// Reveal: unfold every ancestor so the restored selection is visible.
		_hierarchy_open_ancestors(tH)
		restored_scene = true
	}
	if restored_scene {
		_hierarchy_scroll_to_sel = true
	}
	active := ""
	for r in state.proj {
		path, ok := engine.asset_db_get_path(uuid.Identifier(r.guid))
		if !ok do continue // deleted since the snapshot
		_sel_restore_proj(path, r.local_id)
		active = path
	}
	// Keep the active project path in sync (pre-multiselect code reads it,
	// the Assets menu among it), empty included, and navigate the project
	// view to its folder so the restored selection is actually visible.
	_project_set_active(active)
	if active != "" do _project_reveal_keep_selection(active)
}

// Called once per frame from the main loop, after every view has processed
// its input.
selection_undo_track :: proc() {
	// A select request posted this frame (a package menu that created an
	// object) is applied before the diff, so it lands in the create's step.
	// Here as well as in the hierarchy view, which may not be drawn at all.
	hierarchy_apply_pending_select()

	s := undo.get()
	if s == nil do return
	if engine.application_is_playing() do return
	// Rubber-band selection changes live every frame; the baseline stays
	// pre-band so release records the whole gesture as one step.
	if scene_band_selecting() do return

	if !_sel_undo_baseline_valid {
		_sel_undo_baseline = selection_capture_state()
		_sel_undo_baseline_valid = true
		return
	}

	if activity, only_landed := undo.activity_take(s); activity {
		cur := selection_capture_state()
		if only_landed {
			// Takes ownership of both states, frees them when equal.
			undo.amend_top_selection(s, _sel_undo_baseline, cur)
		} else {
			undo.selection_state_destroy(&cur)
			undo.selection_state_destroy(&_sel_undo_baseline)
		}
		_sel_undo_baseline = selection_capture_state()
		return
	}

	cur := selection_capture_state()
	if undo.selection_state_equal(_sel_undo_baseline, cur) {
		undo.selection_state_destroy(&cur)
		return
	}

	label := _selection_label(cur)
	// push_selection takes ownership of both states.
	undo.push_selection(s, _sel_undo_baseline, cur, label)
	undo.activity_take(s) // our own push isn't "activity" for next frame
	_sel_undo_baseline = selection_capture_state()
}

@(private="file")
_selection_label :: proc(st: undo.Selection_State) -> string {
	total := len(st.scene) + len(st.proj)
	if total == 0 do return "Clear Selection"
	if total > 1 do return fmt.tprintf("Select %d Items", total)
	if len(st.scene) == 1 {
		if sc := undo.resolve_scene(st.scene[0].scene); sc != nil {
			if tH, ok := engine.scene_find_selectable_transform_local_id(sc, st.scene[0].local_id); ok {
				w := engine.ctx_world()
				if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
					return strings.concatenate({"Select ", t.name}, context.temp_allocator)
				}
			}
		}
		return "Select"
	}
	if path, ok := engine.asset_db_get_path(uuid.Identifier(st.proj[0].guid)); ok {
		return strings.concatenate({"Select ", filepath.base(path)}, context.temp_allocator)
	}
	return "Select"
}
