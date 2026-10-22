package engine_tests

// A component added to prefab-instance content, or to the instance's host,
// is one component and one added_components record: through Simulate's
// Start and Stop, through a save and reload, and through a save of the
// reloaded scene.

import "core:encoding/uuid"
import "core:os"
import "core:testing"
import sim "moonhug:editor/simulate"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"

@(private = "file")
_count_comps :: proc(w: ^engine.World, tH: engine.Transform_Handle, key: engine.TypeKey) -> int {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return -1
	n := 0
	for c in t.components do if c.handle.type_key == key do n += 1
	return n
}

@(private = "file")
_added_records :: proc(s: ^engine.Scene) -> int {
	n := 0
	for &ns in s.nested_scenes do n += len(ns.added_components)
	return n
}

// The object by its local id, the same across reloads.
@(private = "file")
_by_lid :: proc(w: ^engine.World, s: ^engine.Scene, lid: engine.Local_ID) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene == s && tr.local_id == lid do return engine.Transform_Handle(h)
	}
	return {}
}

// Adds Groups to `tH` and records it on the instance `host` the way the
// inspector's Add Component does.
@(private = "file")
_add_groups :: proc(t: ^testing.T, s: ^engine.Scene, tH, host: engine.Transform_Handle) -> bool {
	tr := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	_, comp_ptr := engine.transform_add_comp(tH, .Groups)
	testing.expect(t, comp_ptr != nil, "adds Groups")
	if comp_ptr == nil do return false
	(cast(^engine.Groups)comp_ptr).groups = 1
	comp_lid := (cast(^engine.CompData)comp_ptr).local_id
	type_guid := uuid.to_string(engine.get_guid_by_type_key(.Groups), context.temp_allocator)
	_, rec_ok := engine.nested_scene_record_component_added(
		s, host, tr.local_id, comp_lid, type_guid,
		comp_ptr, engine.get_typeid_by_type_key(.Groups),
	)
	testing.expect(t, rec_ok, "records the addition")
	return rec_ok
}

@(private = "file")
_noop_tick :: proc(dt: f32, step: bool) {}

@(private = "file")
_host_storage: [1]sim.Host

@(private = "file")
_sim_install :: proc() {
	_host_storage[0] = sim.Host{name = "app", tick = _noop_tick}
	sim.install(sim.Hooks{}, _host_storage[:])
}

@(private = "file")
_sim_uninstall :: proc() {
	sim.install(sim.Hooks{}, sim.hosts())
	sim.shutdown()
}

// Save, reload, count: the addition is one component and `records` records.
@(private = "file")
_expect_round_trip :: proc(t: ^testing.T, w: ^engine.World, s: ^engine.Scene, lid: engine.Local_ID, records: int, path: string, what: string) -> ^engine.Scene {
	testing.expect(t, engine.scene_save(s, path))
	scene := engine.scene_load_single_path(path)
	testing.expectf(t, scene != nil, "%s: reloads", what)
	if scene == nil do return nil
	testing.expectf(t, _count_comps(w, _by_lid(w, scene, lid), .Groups) == 1, "%s: one Groups after the reload", what)
	testing.expectf(t, _added_records(scene) == records, "%s: %d added_components records after the reload", what, records)
	return scene
}

// Instance CONTENT: SpriteA inside HostDup's instance.
@(test)
test_instance_content_added_component_round_trips :: proc(t: ^testing.T) {
	path1 := "moonhug/tests/fixtures/nested_scenes/_HostAddedGroups1.scene"
	path2 := "moonhug/tests/fixtures/nested_scenes/_HostAddedGroups2.scene"
	defer { os.remove(path1); os.remove(path2) }

	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	_sim_install()
	defer _sim_uninstall()

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/HostDup.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	sprite_tH := find_transform_named(&tc.world, loaded, "SpriteA", true)
	st := engine.pool_get(&tc.world.transforms, engine.Handle(sprite_tH))
	inner_host := engine.transform_immediate_nested_host(sprite_tH)
	testing.expect(t, st != nil && inner_host != {}, "finds SpriteA inside the instance")
	if st == nil || inner_host == {} do return
	lid := st.local_id
	if !_add_groups(t, loaded, sprite_tH, inner_host) do return
	testing.expect_value(t, _count_comps(&tc.world, sprite_tH, .Groups), 1)

	// Start keeps the world, Stop reloads it from the snapshot.
	testing.expect(t, sim.start(), "start succeeds")
	testing.expect_value(t, _count_comps(&tc.world, sprite_tH, .Groups), 1)
	sim.stop()
	restored := engine.sm_scene_get_active()
	testing.expect_value(t, _count_comps(&tc.world, _by_lid(&tc.world, restored, lid), .Groups), 1)
	testing.expect_value(t, _added_records(restored), 1)

	// Save and reload, then save the reloaded scene and reload again: the
	// reloaded addition carries a composed lid, and the save has to find it.
	s1 := _expect_round_trip(t, &tc.world, restored, lid, 1, path1, "first save")
	if s1 == nil do return
	_expect_round_trip(t, &tc.world, s1, lid, 1, path2, "save of the reloaded scene")
}

// The instance HOST: BoxAnimated in the demo scene, the absorbed prefab root,
// has the root's components (nested-owned) and takes additions of its own.
@(test)
test_instance_host_added_component_round_trips :: proc(t: ^testing.T) {
	path1 := "plugins/app/assets/demo_prefabs/_host_added_groups1.scene"
	path2 := "plugins/app/assets/demo_prefabs/_host_added_groups2.scene"
	defer { os.remove(path1); os.remove(path2) }

	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init("plugins/app/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	_sim_install()
	defer _sim_uninstall()

	loaded := engine.scene_load_single_path("plugins/app/assets/demo_prefabs/demo_prefabs.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	box_tH := find_transform_named(&tc.world, loaded, "BoxAnimated", false)
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(box_tH))
	testing.expect(t, bt != nil && engine.scene_find_nested_scene_for_host(loaded, box_tH) != nil, "BoxAnimated hosts an instance")
	if bt == nil do return
	lid := bt.local_id
	records := _added_records(loaded) + 1
	if !_add_groups(t, loaded, box_tH, box_tH) do return
	testing.expect_value(t, _count_comps(&tc.world, box_tH, .Groups), 1)

	testing.expect(t, sim.start(), "start succeeds")
	testing.expect_value(t, _count_comps(&tc.world, box_tH, .Groups), 1)
	sim.stop()
	restored := engine.sm_scene_get_active()
	testing.expect_value(t, _count_comps(&tc.world, _by_lid(&tc.world, restored, lid), .Groups), 1)
	testing.expect_value(t, _added_records(restored), records)

	s1 := _expect_round_trip(t, &tc.world, restored, lid, records, path1, "first save")
	if s1 == nil do return
	_expect_round_trip(t, &tc.world, s1, lid, records, path2, "save of the reloaded scene")
}
