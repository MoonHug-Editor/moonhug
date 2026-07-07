package tests

// External (app-package) components must behave EXACTLY like engine components
// in the nested-prefab override machinery. Their serialized form is a plain
// component object in `ext_components` with an extra "__type" guid key, so
// every JSON-level walker (diff/apply/lid-collect) sees the same shape.

import "../app"
import "../engine"

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

PROJECTILE_TYPE_GUID :: "7f5e6f68-938f-467f-993e-4d92adb25233"

// JSON level: diff and apply must see ext components like any other section.
@(test)
test_ext_component_json_diff_and_apply :: proc(t: ^testing.T) {
	base := fmt.tprintf(`{{"ext_components":[{{"__type":"%s","base":{{"local_id":7,"enabled":true}},"speed":3}}]}}`, PROJECTILE_TYPE_GUID)
	work := fmt.tprintf(`{{"ext_components":[{{"__type":"%s","base":{{"local_id":7,"enabled":true}},"speed":99}}]}}`, PROJECTILE_TYPE_GUID)

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer {
		for &ov in out {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
		delete(out)
	}

	testing.expect_value(t, len(out), 1)
	if len(out) != 1 do return
	testing.expect_value(t, out[0].target.local_id, engine.Local_ID(7))
	testing.expect_value(t, out[0].property_path, "speed")

	// Apply the diff back onto base: speed must become 99.
	baked := engine.nested_scene_apply_overrides(transmute([]byte)base, out[:])
	defer if raw_data(baked) != raw_data(transmute([]byte)base) do delete(baked)
	testing.expect(t, strings.contains(string(baked), "\"speed\":99"), "override should bake into ext component json")
}

// Live round trip: instantiate a prefab containing an app component, edit the
// component, save (capture must record an override), reload (apply must
// restore the edit). Identical flow to engine-component overrides.
@(test)
test_ext_component_override_round_trip :: proc(t: ^testing.T) {
	PREFAB_GUID :: "aaaaaaa1-bbb2-4cc3-8dd4-eeeeeeeeeee5"

	dir := "moonhug/tests/_tmp_ext_override"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))

	prefab_path := strings.concatenate({dir, "/proj_prefab.scene"}, context.temp_allocator)
	prefab_meta := strings.concatenate({dir, "/proj_prefab.scene.meta"}, context.temp_allocator)
	host_path := strings.concatenate({dir, "/host.scene"}, context.temp_allocator)
	host_meta := strings.concatenate({dir, "/host.scene.meta"}, context.temp_allocator)
	defer {
		os.remove(prefab_path)
		os.remove(prefab_meta)
		os.remove(host_path)
		os.remove(host_meta)
		os.remove(dir)
	}

	prefab_json := fmt.tprintf(`{{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {{
      "local_id": 1, "name": "ProjRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": [{{"local_id": 7}}]
    }}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "ext_components": [
    {{"__type": "%s", "base": {{"local_id": 7, "enabled": true}}, "speed": 3, "dir": [0,0]}}
  ]
}}`, PROJECTILE_TYPE_GUID)
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	prefab_guid, gerr := uuid.read(PREFAB_GUID)
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(prefab_guid), root)
	testing.expect(t, hostH != {}, "prefab with ext component should instantiate")
	if hostH == {} do return

	// Live app component exists with the authored value.
	find_projectile :: proc(w: ^engine.World) -> ^app.Projectile {
		pool := app.projectiles(w)
		if pool == nil do return nil
		for i in 0..<len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}
	proj := find_projectile(&tc_mem.world)
	testing.expect(t, proj != nil, "live Projectile should exist after instantiate")
	if proj == nil do return
	testing.expect_value(t, proj.speed, f32(3))

	// Edit + save: capture must record an override on the NS.
	proj.speed = 99
	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "host save should succeed")

	captured := false
	for &ns in tc_mem.scene.nested_scenes {
		for ov in ns.overrides {
			if ov.property_path == "speed" do captured = true
		}
	}
	testing.expect(t, captured, "editing an ext component inside a prefab instance should capture a 'speed' override")

	// Reload from disk: apply must restore the edit.
	loaded := engine.scene_load_single_path(host_path)
	testing.expect(t, loaded != nil, "host should reload")
	if loaded == nil do return
	tc_mem.scene = loaded

	proj2 := find_projectile(&tc_mem.world)
	testing.expect(t, proj2 != nil, "Projectile should exist after reload")
	if proj2 == nil do return
	testing.expect_value(t, proj2.speed, f32(99))
}
