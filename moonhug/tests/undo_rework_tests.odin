package tests

// Undo rework coverage (docs/Undo.md): purge instead of clear,
// selection steps, .Asset targets routed through the apply hook.

import "../engine"
import "../editor/undo"

import "core:strings"
import "core:testing"

@(private="file")
_sel_state_proj :: proc(paths: ..string) -> undo.Selection_State {
	proj := make([]string, len(paths))
	for p, i in paths {
		proj[i] = strings.clone(p)
	}
	return undo.Selection_State{proj = proj}
}

@(private="file")
_applied_sel: [dynamic]string

@(private="file")
_test_capture_hook :: proc() -> undo.Selection_State {
	return {}
}

@(private="file")
_test_apply_hook :: proc(state: undo.Selection_State) {
	clear(&_applied_sel)
	for p in state.proj {
		append(&_applied_sel, strings.clone(p))
	}
}

@(test)
test_undo_selection_command :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.set_selection_hooks(_test_capture_hook, _test_apply_hook)
	defer undo.set_selection_hooks(nil, nil)
	defer {
		for p in _applied_sel do delete(p)
		delete(_applied_sel)
		_applied_sel = nil
	}

	undo.push_selection(s, _sel_state_proj("a.mat"), _sel_state_proj("b.mat"), "Select b.mat")
	testing.expect(t, undo.can_undo(s), "selection step recorded")

	undo.apply_undo(s)
	testing.expect_value(t, len(_applied_sel), 1)
	if len(_applied_sel) == 1 do testing.expect_value(t, _applied_sel[0], "a.mat")

	undo.apply_redo(s)
	testing.expect_value(t, len(_applied_sel), 1)
	if len(_applied_sel) == 1 do testing.expect_value(t, _applied_sel[0], "b.mat")
}

@(test)
test_undo_push_selection_skips_equal :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.push_selection(s, _sel_state_proj("same.mat"), _sel_state_proj("same.mat"))
	testing.expect(t, !undo.can_undo(s), "equal states must not record")
}

@(test)
test_undo_purge_scenes_keeps_non_scene_entries :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	// Entry 1: scene-bound transform edit.
	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {1, 2, 3}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	// Entry 2: project-only selection step (no scene references).
	undo.push_selection(s, _sel_state_proj("a.mat"), _sel_state_proj("b.mat"))

	testing.expect_value(t, len(undo.entries(s)), 2)
	testing.expect_value(t, undo.top_index(s), 2)

	undo.purge_scenes(s)

	testing.expect_value(t, len(undo.entries(s)), 1)
	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect(t, undo.can_undo(s), "surviving entry still undoable")

	// Purge counts as stack activity (the selection tracker re-baselines).
	testing.expect(t, undo.activity_consume(s), "purge marks activity")
	testing.expect(t, !undo.activity_consume(s), "activity consumed once")
}

@(test)
test_undo_purge_scene_specific :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {1, 2, 3}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	// Purging an unrelated scene keeps the entry.
	other: engine.Scene
	undo.purge_scene(s, &other)
	testing.expect_value(t, len(undo.entries(s)), 1)

	// Purging the owning scene drops it.
	undo.purge_scene(s, tr.scene)
	testing.expect_value(t, len(undo.entries(s)), 0)
	testing.expect(t, !undo.can_undo(s), "nothing left to undo")
}

@(private="file")
_asset_apply_calls: int

@(private="file")
_asset_apply_last_json: string

@(private="file")
_test_asset_apply :: proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool {
	_asset_apply_calls += 1
	delete(_asset_apply_last_json)
	_asset_apply_last_json = strings.clone(string(json_bytes))
	return true
}

@(test)
test_undo_asset_target_routes_through_hook :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.set_asset_apply(_test_asset_apply)
	defer undo.set_asset_apply(nil)
	_asset_apply_calls = 0
	defer {
		delete(_asset_apply_last_json)
		_asset_apply_last_json = ""
	}

	guid: engine.Asset_GUID
	guid[0] = 42
	target := undo.make_asset_target(guid, typeid_of(int))
	old_json := make([]byte, 1); old_json[0] = '1'
	new_json := make([]byte, 1); new_json[0] = '2'
	undo.push_value(s, target, old_json, new_json)

	undo.apply_undo(s)
	testing.expect_value(t, _asset_apply_calls, 1)
	testing.expect_value(t, _asset_apply_last_json, "1")

	undo.apply_redo(s)
	testing.expect_value(t, _asset_apply_calls, 2)
	testing.expect_value(t, _asset_apply_last_json, "2")
}
