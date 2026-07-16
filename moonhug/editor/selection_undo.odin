package editor

// Selection changes as undo steps (Unity model): a per-frame tracker diffs
// the selection against a baseline and pushes one Selection_Command per
// changed frame — a click, a shift-range, an Escape-clear each become one
// "Select ..." entry. Frames where the undo stack itself mutated (data edit
// pushed, undo/redo applied, purge on scene navigation) only re-baseline, so
// data operations never double-record their selection side effects; delete/
// duplicate groups restore selection through their own embedded snapshot
// (undo.record_selection_snapshot).
//
// The undo package can't import this package, so capture/apply are installed
// as hooks (selection_undo_install, called next to undo.install in main).

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
	items := make([dynamic]undo.Selection_Scene_Item)
	if w != nil {
		for h in sel_scene_items() {
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil do continue
			append(&items, undo.Selection_Scene_Item{
				scene    = undo.scene_ref(t.scene),
				local_id = t.local_id,
			})
		}
	}
	proj := make([dynamic]string)
	for p in sel_proj_items() {
		append(&proj, strings.clone(p))
	}
	return undo.Selection_State{scene = items[:], proj = proj[:]}
}

selection_apply_state :: proc(state: undo.Selection_State) {
	sel_scene_clear()
	restored_scene := false
	for it in state.scene {
		sc := undo.resolve_scene(it.scene)
		if sc == nil do continue
		tH, ok := engine.scene_find_selectable_transform_local_id(sc, it.local_id)
		if !ok do continue
		sel_scene_add(tH)
		// Reveal: unfold every ancestor so the restored selection is visible.
		_hierarchy_open_ancestors(tH)
		restored_scene = true
	}
	if restored_scene {
		_hierarchy_scroll_to_sel = true
	}
	sel_proj_clear()
	for p in state.proj {
		sel_proj_add(p)
	}
	// Keep the active project path in sync (pre-multiselect code reads it)
	// and navigate the project view to its folder so the restored selection
	// is actually visible.
	if len(state.proj) > 0 {
		active := state.proj[len(state.proj) - 1]
		_project_set_active(active)
		_project_reveal_keep_selection(active)
	}
}

// Called once per frame from the main loop, after every view has processed
// its input.
selection_undo_track :: proc() {
	s := undo.get()
	if s == nil do return
	if engine.ctx_get().is_playmode do return
	// Rubber-band selection changes live every frame; the baseline stays
	// pre-band so release records the whole gesture as one step.
	if scene_band_selecting() do return

	if !_sel_undo_baseline_valid {
		_sel_undo_baseline = selection_capture_state()
		_sel_undo_baseline_valid = true
		return
	}

	if undo.activity_consume(s) {
		undo.selection_state_destroy(&_sel_undo_baseline)
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
	undo.activity_consume(s) // our own push isn't "activity" for next frame
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
	return strings.concatenate({"Select ", filepath.base(st.proj[0])}, context.temp_allocator)
}
