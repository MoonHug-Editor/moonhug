package tests

// Undo across Play (editor/simulate with undo.play_begin/play_end):
// - while playing, undo and redo walk only this run's steps
// - Stop drops the run's scene steps and keeps its other steps
// - every step from before Play still works on the scene Stop restores
// Stop frees the Scene struct and loads a new one, so a step from before Play
// finds it by session id. The test scene is unsaved (no guid), and the second
// test loads one scene file twice (same guid), the two cases where no other
// identity finds the right scene.

import "core:testing"
import "../editor"
import "../editor/menu"
import "../editor/simulate"
import "../editor/undo"
import "../engine"

@(private = "file")
_hosts := [1]simulate.Host{{name = "play_undo_test", update = proc(dt: f32) {}, fixed_update = proc(dt: f32) {}}}

// Stands in for data Stop does not roll back (an asset, a project setting).
@(private = "file")
_setting: int

@(private = "file")
_set_intensity :: proc(owned: engine.Owned, p: ^engine.Light, v: f32) {
	undo.push_component_owner(owned.handle)
	defer undo.pop_owner()
	e := undo.edit_begin(owned.handle, &p.intensity, typeid_of(f32))
	p.intensity = v
	undo.edit_end(&e)
}

@(private = "file")
_light_in :: proc(sc: ^engine.Scene, lid: engine.Local_ID) -> ^engine.Light {
	tH, ok := engine.scene_find_selectable_transform_local_id(sc, lid)
	if !ok do return nil
	_, p := engine.transform_get_comp(tH, engine.Light)
	return p
}

@(private = "file")
_new_lamp :: proc(parent: engine.Transform_Handle, intensity: f32) -> (engine.Owned, ^engine.Light, engine.Local_ID) {
	tH := engine.transform_new("Lamp", parent)
	lid := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).local_id
	owned, p := engine.transform_get_or_add_comp(tH, engine.Light)
	if p != nil do p.intensity = intensity
	return owned, p, lid
}

@(test)
test_stop_drops_play_steps_and_keeps_steps_from_before_play :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	simulate.install({}, _hosts[:])
	defer simulate.install({}, nil)
	defer simulate.stop() // a failed expect must not leave the run going

	owned, p, lid := _new_lamp(engine.Transform_Handle(tc.scene.root.handle), 55)
	if p == nil do return
	_set_intensity(owned, p, 123) // before Play

	testing.expect(t, simulate.start(), "Play starts")
	_set_intensity(owned, p, 200) // during Play, a scene step
	_setting = 0
	se := undo.edit_raw_begin(&_setting, typeid_of(int), &_setting, typeid_of(int), "Setting")
	_setting = 7
	undo.edit_end(&se) // during Play, not a scene step
	testing.expect_value(t, len(s.items), 3)

	testing.expect(t, !undo.jump_to(s, 0), "a jump past the run's steps does nothing")
	testing.expect_value(t, undo.top_index(s), 3)

	// Through the Edit menu, the path Cmd+Z takes: its enabled predicate must
	// allow the run's steps while playing.
	editor._register_menu_items()
	defer menu.shutdown_menu()
	undone1, _ := menu.invoke_path("Edit/Undo")
	undone2, _ := menu.invoke_path("Edit/Undo")
	testing.expect(t, undone1 && undone2, "Edit/Undo undoes the run's two steps")
	testing.expect_value(t, p.intensity, f32(123))
	locked, _ := menu.invoke_path("Edit/Undo")
	testing.expect(t, !locked, "the step from before Play is locked while playing")
	redone1, _ := menu.invoke_path("Edit/Redo")
	redone2, _ := menu.invoke_path("Edit/Redo")
	testing.expect(t, redone1 && redone2, "Edit/Redo redoes them")
	testing.expect_value(t, _setting, 7)

	simulate.stop()
	testing.expect_value(t, len(s.items), 2)
	sc := engine.sm_scene_get_active()
	restored := _light_in(sc, lid)
	testing.expect(t, restored != nil && restored.intensity == 123, "Stop restores the value from before Play")

	testing.expect(t, undo.apply_undo(s), "the setting step from Play undoes")
	testing.expect_value(t, _setting, 0)
	testing.expect(t, undo.apply_undo(s), "the step from before Play undoes")
	restored = _light_in(sc, lid)
	testing.expect(t, restored != nil && restored.intensity == 55, "it reverts on the restored scene")
}

// One scene file loaded twice: both copies carry the same guid, so only the
// session id tells them apart after Stop reloads the played copy.
@(test)
test_undo_after_stop_finds_the_played_copy_of_a_twice_loaded_scene :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	simulate.install({}, _hosts[:])
	defer simulate.install({}, nil)
	defer simulate.stop()

	guid := engine.Asset_GUID{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	first := tc.scene
	first.asset_guid = guid
	_, first_lamp, first_lid := _new_lamp(engine.Transform_Handle(first.root.handle), 999)
	if first_lamp == nil do return

	second := engine.scene_new()
	second.asset_guid = guid
	engine.sm_scene_set_active(second)
	engine.scene_ensure_root(second)
	owned, p, lid := _new_lamp(engine.Transform_Handle(second.root.handle), 55)
	if p == nil do return
	_set_intensity(owned, p, 123) // before Play, in the second copy

	testing.expect(t, simulate.start(), "Play starts on the second copy")
	simulate.stop()

	played := engine.sm_scene_get_active()
	testing.expect(t, undo.apply_undo(s), "the step from before Play undoes")
	lamp := _light_in(played, lid)
	testing.expect(t, lamp != nil && lamp.intensity == 55, "it reverts in the copy that played")
	other := _light_in(first, first_lid)
	testing.expect(t, other != nil && other.intensity == 999, "the other copy is untouched")
}
