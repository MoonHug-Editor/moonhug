package tests

import "../engine"
import sprites "moonhug:packages/sprites"

import "core:os"
import "core:strings"
import "core:testing"

// The snapshot/restore mechanism behind the editor's in-editor Simulate
// (editor/simulate.odin). Simulate captures with engine.scene_serialize and
// restores with engine.scene_load_single_bytes, so revert-after-play is only as
// good as that pair — these tests pin the pair, not the UI.
//
// The editor package can't be imported here, so the Sim_State machine itself is
// not covered; what IS covered is the property the whole feature rests on: bytes
// out of a live scene load back into an equivalent live scene.

// Gameplay mutates the world, then restore puts the captured values back.
@(test)
test_simulate_snapshot_restores_mutated_values :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_snapshot.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	tH := engine.transform_new("Mover", engine.Transform_Handle(s.root.handle))
	testing.expect(t, tH != {}, "authored a transform to mutate")
	if tH == {} do return

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	testing.expect(t, tr != nil)
	if tr == nil do return
	tr.position = {1, 2, 3}
	lid := tr.local_id

	// Capture, exactly as sim_start does.
	snapshot, ok := engine.scene_serialize(s)
	testing.expect(t, ok, "scene_serialize captured the live scene")
	if !ok do return
	defer delete(snapshot)

	// "Play": move the object somewhere else.
	tr.position = {99, 99, 99}

	// Stop: restore from the captured bytes.
	restored := engine.scene_load_single_bytes(snapshot, {}, s.path)
	testing.expect(t, restored != nil, "snapshot loaded back")
	if restored == nil do return
	tc_mem.scene = restored

	// Re-resolve by local id — handles do not survive the reload, which is why
	// simulate.odin snapshots selection as lids.
	rH, found := engine.scene_find_selectable_transform_local_id(restored, lid)
	testing.expect(t, found, "object found again by local id after restore")
	if !found do return

	rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(rH))
	testing.expect(t, rt != nil)
	if rt == nil do return
	testing.expectf(t, rt.position == [3]f32{1, 2, 3},
		"restore returns the captured position, got %v", rt.position)
}

// Objects the "game" spawned during play are gone after restore, and objects it
// destroyed are back. Both directions matter: a snapshot that only re-applied
// field values would pass the test above and fail this one.
@(test)
test_simulate_snapshot_restores_object_set :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_objects.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	s := tc_mem.scene
	keep := engine.transform_new("Keep", engine.Transform_Handle(s.root.handle))
	doomed := engine.transform_new("Doomed", engine.Transform_Handle(s.root.handle))
	testing.expect(t, keep != {} && doomed != {})
	if keep == {} || doomed == {} do return

	keep_lid: engine.Local_ID
	doomed_lid: engine.Local_ID
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(keep)); tr != nil {
		keep_lid = tr.local_id
	}
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(doomed)); tr != nil {
		doomed_lid = tr.local_id
	}

	snapshot, ok := engine.scene_serialize(s)
	testing.expect(t, ok)
	if !ok do return
	defer delete(snapshot)

	// "Play": spawn one object, destroy another.
	spawned := engine.transform_new("SpawnedAtRuntime", engine.Transform_Handle(s.root.handle))
	testing.expect(t, spawned != {})
	engine.transform_destroy(doomed)

	restored := engine.scene_load_single_bytes(snapshot, {}, s.path)
	testing.expect(t, restored != nil)
	if restored == nil do return
	tc_mem.scene = restored

	_, keep_found := engine.scene_find_selectable_transform_local_id(restored, keep_lid)
	testing.expect(t, keep_found, "untouched object survives restore")

	_, doomed_found := engine.scene_find_selectable_transform_local_id(restored, doomed_lid)
	testing.expect(t, doomed_found, "object destroyed during play is back after restore")

	runtime_spawn := find_transform_named(&tc_mem.world, restored, "SpawnedAtRuntime", false)
	testing.expect(t, runtime_spawn == {}, "object spawned during play is gone after restore")
}

// Restore is scoped to ONE scene: an additively loaded second scene survives it.
// Without scoping, restore reloads the whole world and destroys the additive
// scene, which was never captured and so cannot be brought back.
@(test)
test_simulate_restore_preserves_additive_scenes :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_additive.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// The simulated scene.
	sim_scene := tc_mem.scene
	tH := engine.transform_new("Mover", engine.Transform_Handle(sim_scene.root.handle))
	testing.expect(t, tH != {})
	if tH == {} do return
	lid: engine.Local_ID
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH)); tr != nil {
		tr.position = {1, 2, 3}
		lid = tr.local_id
	}

	snapshot, ok := engine.scene_serialize(sim_scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(snapshot)

	// A second scene, loaded additively — the thing that must survive.
	extra_path := "moonhug/tests/fixtures/_test_sim_additive_extra.scene"
	testing.expect(t, fixture_write_empty_scene(extra_path, "ExtraRoot"),
		"wrote the additive fixture")
	defer os.remove(extra_path)
	extra := engine.scene_load_additive_path(extra_path)
	testing.expect(t, extra != nil, "additive scene loaded")
	if extra == nil do return

	// "Play" moves the object.
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH)); tr != nil {
		tr.position = {99, 99, 99}
	}

	// Stop: restore only the simulated scene.
	restored := engine.scene_reload_in_place_bytes(
		sim_scene, snapshot, sim_scene.asset_guid, sim_scene.path)
	testing.expect(t, restored != nil, "in-place restore succeeded")
	if restored == nil do return
	tc_mem.scene = restored

	// The additive scene is still loaded, and is still the SAME Scene — restore
	// must not have recreated it either.
	testing.expect(t, engine.sm_scene_is_loaded(extra),
		"additively loaded scene survives an in-place restore")

	extra_root := engine.pool_get(&tc_mem.world.transforms,
		engine.Handle(extra.root.handle))
	testing.expect(t, extra_root != nil, "additive scene's root is still alive")

	// And the simulated scene really did revert.
	rH, found := engine.scene_find_selectable_transform_local_id(restored, lid)
	testing.expect(t, found)
	if !found do return
	rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(rH))
	testing.expect(t, rt != nil)
	if rt != nil {
		testing.expectf(t, rt.position == [3]f32{1, 2, 3},
			"simulated scene reverted, got %v", rt.position)
	}
}

// The restored scene keeps its slot and its active-scene status, so the editor
// carries on editing the same scene rather than silently switching.
@(test)
test_simulate_restore_keeps_active_scene :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_active.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	PATH :: "moonhug/tests/fixtures/_test_sim_active.scene"

	sim_scene := tc_mem.scene
	engine.sm_scene_set_active(sim_scene)
	// setup() leaves path empty; restore is supposed to carry whatever the scene
	// had, so set it to something observable first.
	if sim_scene.path != "" do delete(sim_scene.path)
	sim_scene.path = strings.clone(PATH)

	snapshot, ok := engine.scene_serialize(sim_scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(snapshot)

	restored := engine.scene_reload_in_place_bytes(
		sim_scene, snapshot, sim_scene.asset_guid, sim_scene.path)
	testing.expect(t, restored != nil)
	if restored == nil do return
	tc_mem.scene = restored

	testing.expect(t, engine.sm_scene_get_active() == restored,
		"the restored scene is still the active scene")
	testing.expectf(t, restored.path == PATH,
		"path carried across restore, got %q want %q", restored.path, PATH)
}

// A scene with a nested prefab instance and an override on it: the override must
// survive capture/restore, since Simulate runs on whatever the user has open —
// which is usually a scene with prefabs in it.
@(test)
test_simulate_snapshot_preserves_nested_override :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_sim_snapshot")
	if !fx_ok do return

	// bullet_Variant is a variant whose inherited content carries an override —
	// the shape Simulate actually meets in a real scene.
	loaded := engine.scene_load_single_path(fx.bv_path)
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	sr, sr_tH := fixture_find_sprite(&tc_mem.world, loaded, nested_only = true)
	testing.expect(t, sr != nil && sr_tH != {}, "found a sprite inside the nested instance")
	if sr == nil || sr_tH == {} do return

	// Author an override on prefab content, the way the inspector would.
	override_color := [4]f32{0.25, 0.5, 0.75, 1}
	sr.color = override_color

	lid: engine.Local_ID
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(sr_tH)); tr != nil {
		lid = tr.local_id
	}
	testing.expect(t, lid != 0)
	if lid == 0 do return

	snapshot, ok := engine.scene_serialize(loaded)
	testing.expect(t, ok)
	if !ok do return
	defer delete(snapshot)

	// "Play" stomps the overridden value.
	sr.color = {1, 0, 0, 1}

	restored := engine.scene_load_single_bytes(
		snapshot, loaded.asset_guid, loaded.path)
	testing.expect(t, restored != nil)
	if restored == nil do return
	tc_mem.scene = restored

	rH, found := engine.scene_find_selectable_transform_local_id(restored, lid)
	testing.expect(t, found, "nested object found by lid after restore")
	if !found do return

	_, rsr := engine.transform_get_comp(rH, sprites.SpriteRenderer)
	testing.expect(t, rsr != nil, "sprite component present after restore")
	if rsr == nil do return
	testing.expectf(t, fixture_color_close(rsr.color, override_color),
		"override survives snapshot/restore, got %v want %v", rsr.color, override_color)
}
