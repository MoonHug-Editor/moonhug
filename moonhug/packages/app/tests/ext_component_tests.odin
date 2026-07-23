package app_tests

// External (app-package) components must behave EXACTLY like engine components
// in the nested-prefab override machinery. Their serialized form is a plain
// component object in `ext_components` with an extra "__type" guid key, so
// every JSON-level walker (diff/apply/lid-collect) sees the same shape.

import app ".."
import "moonhug:engine"
import common "moonhug:tests/common"

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

PROJECTILE_TYPE_GUID :: "7f5e6f68-938f-467f-993e-4d92adb25233"
TANK_TYPE_GUID :: "f15b003c-a491-4aec-b838-49e641a25346"

// JSON level: diff and apply must see ext components like any other section.
@(test)
test_ext_component_json_diff_and_apply :: proc(t: ^testing.T) {
	base := fmt.tprintf(`{{"components":[{{"__type":"%s","base":{{"local_id":7,"enabled":true}},"speed":3}}]}}`, PROJECTILE_TYPE_GUID)
	work := fmt.tprintf(`{{"components":[{{"__type":"%s","base":{{"local_id":7,"enabled":true}},"speed":99}}]}}`, PROJECTILE_TYPE_GUID)

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
  "components": [
    {{"__type": "%s", "base": {{"local_id": 7, "enabled": true}}, "speed": 3, "dir": [0,0]}}
  ]
}}`, PROJECTILE_TYPE_GUID)
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

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

// Intra-prefab references: an ext component INSIDE a nested prefab whose
// Ref_Local fields point at other transforms of the same prefab must resolve
// after instantiation. The prefab keeps its own local_id namespace (its ids
// never enter the host bimap), so resolution must use the prefab file's own
// id table — resolving against the host bimap leaves the refs dangling (or
// binds them to same-numbered host objects). Regression test for the tank
// demo's Tank{turret, shoot_from} coming up unresolved.
@(test)
test_ext_component_nested_intra_prefab_refs :: proc(t: ^testing.T) {
	PREFAB_GUID :: "bbbbbbb1-ccc2-4dd3-8ee4-fffffffffff6"

	dir := "moonhug/tests/_tmp_ext_nested_refs"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))

	prefab_path := strings.concatenate({dir, "/tank_prefab.scene"}, context.temp_allocator)
	prefab_meta := strings.concatenate({dir, "/tank_prefab.scene.meta"}, context.temp_allocator)
	defer {
		os.remove(prefab_path)
		os.remove(prefab_meta)
		os.remove(dir)
	}

	// Root(1) carries the Tank(7); Turret(2) and ShootFrom(3) are children.
	// The Tank's refs use the PREFAB's local ids — the whole point of the test.
	prefab_json := fmt.tprintf(`{{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {{
      "local_id": 1, "name": "TankRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [
        {{"pptr": {{"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}}},
        {{"pptr": {{"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}}}
      ],
      "components": [{{"local_id": 7}}]
    }},
    {{
      "local_id": 2, "name": "Turret", "is_active": true,
      "position": [0,1,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []
    }},
    {{
      "local_id": 3, "name": "ShootFrom", "is_active": true,
      "position": [0,2,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []
    }}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 7, "enabled": true}},
      "turret": {{"local_id": 2}}, "shoot_from": {{"local_id": 1}},
      "projectile_prefab": "00000000-0000-0000-0000-000000000000"}}
  ]
}}`, TANK_TYPE_GUID)
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	prefab_guid, gerr := uuid.read(PREFAB_GUID)
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(prefab_guid), root)
	testing.expect(t, hostH != {}, "nested prefab with Tank should instantiate")
	if hostH == {} do return

	w := &tc_mem.world
	find_tank :: proc(w: ^engine.World) -> ^app.Tank {
		pool := app.tanks(w)
		if pool == nil do return nil
		for i in 0..<len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}
	tank := find_tank(w)
	testing.expect(t, tank != nil, "live Tank should exist after nested instantiate")
	if tank == nil do return

	// All three refs must be live transform handles pointing at the right nodes.
	check_ref :: proc(t: ^testing.T, w: ^engine.World, r: engine.Ref_Local, want_name: string) {
		testing.expect(t, engine.pool_valid(&w.transforms, r.handle),
			fmt.tprintf("%s: handle should be valid (got %v)", want_name, r.handle))
		tr := engine.pool_get(&w.transforms, r.handle)
		if tr != nil {
			testing.expect_value(t, tr.name, want_name)
		}
	}
	check_ref(t, w, tank.turret, "Turret")
	// shoot_from points at the PREFAB ROOT (lid 1) in this fixture: the root is
	// absorbed into the host on instantiation, so the ref must land on the HOST
	// transform (regression for the root-handle redirect).
	testing.expect(t, tank.shoot_from.handle == engine.Handle(hostH),
		fmt.tprintf("ref to prefab root should bind to the host transform (got %v, want %v)", tank.shoot_from.handle, hostH))
}

// Editing a Ref_Local INSIDE a nested prefab instance (repointing it at another
// object of the same instance, as the inspector picker does) must capture an
// override — the differ must see ref VALUES ({"local_id": N}), excluding only
// record identity paths — and the override must survive save/reload, resolving
// through the breadcrumb the picker minted. Regression for: ref edits silently
// reverting on reload.
@(test)
test_ext_component_ref_override_round_trip :: proc(t: ^testing.T) {
	PREFAB_GUID :: "ccccccc1-ddd2-4ee3-8ff4-000000000007"

	dir := "moonhug/tests/_tmp_ext_ref_override"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))

	prefab_path := strings.concatenate({dir, "/tank_prefab.scene"}, context.temp_allocator)
	prefab_meta := strings.concatenate({dir, "/tank_prefab.scene.meta"}, context.temp_allocator)
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
      "local_id": 1, "name": "TankRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [
        {{"pptr": {{"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}}},
        {{"pptr": {{"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}}}
      ],
      "components": [{{"local_id": 7}}]
    }},
    {{
      "local_id": 2, "name": "Turret", "is_active": true,
      "position": [0,1,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []
    }},
    {{
      "local_id": 3, "name": "Barrel", "is_active": true,
      "position": [0,2,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []
    }}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 7, "enabled": true}},
      "turret": {{"local_id": 2}}, "shoot_from": {{"local_id": 3}},
      "projectile_prefab": "00000000-0000-0000-0000-000000000000"}}
  ]
}}`, TANK_TYPE_GUID)
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	prefab_guid, gerr := uuid.read(PREFAB_GUID)
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(prefab_guid), root)
	testing.expect(t, hostH != {}, "prefab should instantiate")
	if hostH == {} do return

	w := &tc_mem.world
	find_tank :: proc(w: ^engine.World) -> ^app.Tank {
		pool := app.tanks(w)
		if pool == nil do return nil
		for i in 0..<len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}
	find_transform :: proc(w: ^engine.World, name: string) -> engine.Handle {
		for i in 0..<len(w.transforms.slots) {
			sl := &w.transforms.slots[i]
			if sl.alive && sl.data.name == name {
				return engine.Handle{index = u32(i), generation = sl.generation, type_key = .Transform}
			}
		}
		return {}
	}

	tank := find_tank(w)
	testing.expect(t, tank != nil)
	if tank == nil do return

	// Repoint turret at Barrel, exactly as the inspector picker does.
	barrel := find_transform(w, "Barrel")
	testing.expect(t, barrel != {}, "Barrel should exist")
	tank.turret.handle = barrel
	tank.turret.local_id = engine.sm_local_id_get_or_mint(tc_mem.scene, barrel)
	testing.expect(t, tank.turret.local_id != 0, "picker mint should produce a lid for a nested target")

	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "host save should succeed")

	captured := false
	for &ns in tc_mem.scene.nested_scenes {
		for ov in ns.overrides {
			if ov.property_path == "turret.local_id" do captured = true
		}
	}
	testing.expect(t, captured, "repointing a ref inside a prefab instance should capture a 'turret.local_id' override")

	// Reload: the override must apply and the ref must resolve to Barrel.
	loaded := engine.scene_load_single_path(host_path)
	testing.expect(t, loaded != nil, "host should reload")
	if loaded == nil do return
	tc_mem.scene = loaded

	tank2 := find_tank(w)
	testing.expect(t, tank2 != nil)
	if tank2 == nil do return
	testing.expect(t, engine.pool_valid(&w.transforms, tank2.turret.handle),
		fmt.tprintf("turret should resolve after reload (got %v)", tank2.turret.handle))
	tr := engine.pool_get(&w.transforms, tank2.turret.handle)
	if tr != nil {
		testing.expect_value(t, tr.name, "Barrel")
	}

	// The inspector draws the whole Ref_Local as ONE field at path "turret";
	// the override is stored at "turret.local_id". Coloring must see it
	// (prefix-covered), and revert at the field path must restore the baseline
	// (Turret), rebind the handle in the instance's namespace, and drop the
	// stored override.
	host2 := engine.Transform_Handle(engine.Handle(tank2.owner))
	testing.expect(t, engine.nested_scene_has_root_override(tc_mem.scene, host2, tank2.local_id, "turret"),
		"field-level override check should cover the 'turret.local_id' record")

	root_ns, root_target, loc_ok := engine.nested_scene_locate_root_override(tc_mem.scene, host2, tank2.local_id)
	testing.expect(t, loc_ok, "root override location should resolve")
	if loc_ok {
		engine.nested_scene_revert_override(tc_mem.scene, root_ns, root_target, "turret", &tank2.turret)
		tr2 := engine.pool_get(&w.transforms, tank2.turret.handle)
		testing.expect(t, tr2 != nil, "reverted turret ref should hold a live handle")
		if tr2 != nil {
			testing.expect_value(t, tr2.name, "Turret")
		}
		testing.expect(t, !engine.nested_scene_has_root_override(tc_mem.scene, host2, tank2.local_id, "turret"),
			"revert should remove the covered override record")
	}
}

// A HOST-scene component referencing content INSIDE a nested instance: the
// picker mint must hand back the instance's composed lid (bit 52 set — no
// breadcrumb), the composed lid must persist through save, and reload must
// re-derive the identical lid (deterministic hash) and rebind the handle.
// This is the save/load leg of the composed-instance-lid model.
@(test)
test_host_ref_into_nested_instance_round_trip :: proc(t: ^testing.T) {
	PREFAB_GUID :: "ddddddd1-eee2-4ff3-8004-000000000008"

	dir := "moonhug/tests/_tmp_host_ref_nested"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))

	prefab_path := strings.concatenate({dir, "/tank_prefab.scene"}, context.temp_allocator)
	prefab_meta := strings.concatenate({dir, "/tank_prefab.scene.meta"}, context.temp_allocator)
	host_path := strings.concatenate({dir, "/host.scene"}, context.temp_allocator)
	host_meta := strings.concatenate({dir, "/host.scene.meta"}, context.temp_allocator)
	defer {
		os.remove(prefab_path)
		os.remove(prefab_meta)
		os.remove(host_path)
		os.remove(host_meta)
		os.remove(dir)
	}

	prefab_json := `{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {
      "local_id": 1, "name": "TankRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [
        {"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}
      ],
      "components": []
    },
    {
      "local_id": 2, "name": "Turret", "is_active": true,
      "position": [0,1,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": []
    }
  ],
  "nested_scenes": [], "breadcrumbs": [], "components": []
}`
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	prefab_guid, gerr := uuid.read(PREFAB_GUID)
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(prefab_guid), root)
	testing.expect(t, hostH != {}, "prefab should instantiate")
	if hostH == {} do return

	w := &tc_mem.world
	find_transform :: proc(w: ^engine.World, name: string) -> engine.Handle {
		for i in 0..<len(w.transforms.slots) {
			sl := &w.transforms.slots[i]
			if sl.alive && sl.data.name == name {
				return engine.Handle{index = u32(i), generation = sl.generation, type_key = .Transform}
			}
		}
		return {}
	}
	find_refs :: proc(w: ^engine.World) -> ^app.SceneRefs {
		pool := app.scene_refses(w)
		if pool == nil do return nil
		for i in 0..<len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}

	// SceneRefs lives on the HOST scene root — outside the instance.
	_, raw := engine.transform_add_comp(root, .SceneRefs)
	refs := cast(^app.SceneRefs)raw
	testing.expect(t, refs != nil, "SceneRefs should attach to the scene root")
	if refs == nil do return

	turret := find_transform(w, "Turret")
	testing.expect(t, turret != {}, "Turret should exist inside the instance")

	// Point at nested content exactly as the inspector picker does.
	refs.tank.handle = turret
	refs.tank.local_id = engine.sm_local_id_get_or_mint(tc_mem.scene, turret)
	testing.expect(t, refs.tank.local_id & engine.INSTANCE_LID_BIT != 0,
		fmt.tprintf("mint for nested content should return the composed instance lid (got %v)", refs.tank.local_id))

	minted_lid := refs.tank.local_id
	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "host save should succeed")

	// Reload: the composed lid must re-derive identically and rebind to Turret.
	loaded := engine.scene_load_single_path(host_path)
	testing.expect(t, loaded != nil, "host should reload")
	if loaded == nil do return
	tc_mem.scene = loaded

	refs2 := find_refs(w)
	testing.expect(t, refs2 != nil, "SceneRefs should exist after reload")
	if refs2 == nil do return
	testing.expect_value(t, refs2.tank.local_id, minted_lid)
	testing.expect(t, engine.pool_valid(&w.transforms, refs2.tank.handle),
		fmt.tprintf("host ref into instance should resolve after reload (got %v)", refs2.tank.handle))
	tr := engine.pool_get(&w.transforms, refs2.tank.handle)
	if tr != nil {
		testing.expect_value(t, tr.name, "Turret")
	}
}
