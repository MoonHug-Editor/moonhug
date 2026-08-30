package tests

// Multi-scene lifecycle hardening. The nested_owned pool-recycling bug hid
// from every single-scene-per-world test: component loss only appeared after
// open scene A → open scene B (A's slots recycle) → save B. These tests keep
// the world dirty across loads, unloads and saves so that class of bug
// surfaces in CI instead of in saved files.

import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import sprites "moonhug:packages/sprites"


@(private = "file")
_find_sprite_in_scene :: proc(w: ^engine.World, s: ^engine.Scene) -> ^sprites.SpriteRenderer {
	it := engine.pool_iterator(&w.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, sr := engine.transform_get_comp(h, sprites.SpriteRenderer)
		if sr != nil do return sr
	}
	return nil
}

// Saving a prefab while SEVERAL scenes that nest it are loaded must propagate
// the edit into every one of them — `_propagate_prefab_save` walks all loaded
// scenes, not just the active one. Editor flow: host A open, host B open
// additively, prefab P opened additively, P edited and saved.
@(test)
test_prefab_save_propagates_to_all_loaded_scenes :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_multiscene_prop"
	os.make_directory(dir)
	p_path := strings.concatenate({dir, "/p.scene"}, context.temp_allocator)
	a_path := strings.concatenate({dir, "/a.scene"}, context.temp_allocator)
	b_path := strings.concatenate({dir, "/b.scene"}, context.temp_allocator)
	defer {
		for f in ([]string{p_path, a_path, b_path}) {
			os.remove(f)
			os.remove(strings.concatenate({f, ".meta"}, context.temp_allocator))
		}
		os.remove(dir)
	}

	SPRITE_GUID :: "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"
	COLOR_OLD := [4]f32{0.5, 0, 0, 1}
	COLOR_NEW := [4]f32{0, 0, 1, 1}

	p_json := `{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {
      "local_id": 1, "name": "PRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": [{"local_id": 3}]
    }
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "` + SPRITE_GUID + `",
     "base": {"local_id": 3, "enabled": true},
     "texture": "00000000-0000-0000-0000-000000000000",
     "color": [0.5, 0, 0, 1]}
  ]
}`
	testing.expect(t, os.write_entire_file(p_path, transmute([]byte)p_json) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	p_guid, gok := engine.asset_db_get_guid(p_path)
	testing.expect(t, gok, "p.scene registered")

	// Author hosts A and B, each nesting P.
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(p_guid), engine.Transform_Handle(tc.scene.root.handle))
	testing.expect(t, hostH != {}, "P instantiates into host")
	testing.expect(t, engine.scene_save(tc.scene, a_path), "save host A")
	testing.expect(t, engine.scene_save(tc.scene, b_path), "save host B")

	// Editor state: A open, B open additively, P open additively.
	sA := engine.scene_load_single_path(a_path)
	testing.expect(t, sA != nil, "host A loads")
	if sA == nil do return
	tc.scene = sA
	engine.sm_scene_set_active(sA)
	sB := engine.scene_load_additive_path(b_path)
	testing.expect(t, sB != nil, "host B loads additively")
	if sB == nil do return
	defer engine.sm_scene_destroy_or_unload(sB)
	sP := engine.scene_load_additive_path(p_path)
	testing.expect(t, sP != nil, "prefab P loads additively")
	if sP == nil do return
	defer engine.sm_scene_destroy_or_unload(sP)

	// Both hosts see the authored color before the edit.
	w := &tc.world
	for host in ([]^engine.Scene{sA, sB}) {
		sr := _find_sprite_in_scene(w, host)
		testing.expect(t, sr != nil, "host instance has the sprite")
		if sr != nil do testing.expect_value(t, sr.color, COLOR_OLD)
	}

	// Edit P live and save it — the propagation pass must rebuild the
	// instances in BOTH loaded hosts.
	p_sr := _find_sprite_in_scene(w, sP)
	testing.expect(t, p_sr != nil, "prefab sprite found")
	if p_sr == nil do return
	p_sr.color = COLOR_NEW
	testing.expect(t, engine.scene_save(sP, p_path), "save prefab")

	for host in ([]^engine.Scene{sA, sB}) {
		sr := _find_sprite_in_scene(w, host)
		testing.expect(t, sr != nil, "host instance survives propagation")
		if sr != nil do testing.expect_value(t, sr.color, COLOR_NEW)
	}
}

// Unloading one additive scene recycles its pool slots; filling those slots
// with NEW content must leave the surviving scenes' serialized bytes
// untouched. Snapshot-compare: serialize scene X before and after the churn.
@(test)
test_additive_unload_slot_reuse_keeps_survivors_intact :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_slot_reuse"
	os.make_directory(dir)
	x_path := strings.concatenate({dir, "/x.scene"}, context.temp_allocator)
	x_meta := strings.concatenate({dir, "/x.scene.meta"}, context.temp_allocator)
	defer { os.remove(x_path); os.remove(x_meta); os.remove(dir) }

	SPRITE_GUID :: "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"
	x_json := `{
  "root": 1,
  "next_local_id": 20,
  "transforms": [
    {
      "local_id": 1, "name": "XRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [
        {"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}},
        {"pptr": {"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}
      ],
      "components": []
    },
    {
      "local_id": 2, "name": "XA", "is_active": true,
      "position": [1,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": [{"local_id": 12}]
    },
    {
      "local_id": 3, "name": "XB", "is_active": true,
      "position": [2,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": [{"local_id": 13}]
    }
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "` + SPRITE_GUID + `",
     "base": {"local_id": 12, "enabled": true},
     "texture": "00000000-0000-0000-0000-000000000000", "color": [1, 0, 0, 1]},
    {"__type": "` + SPRITE_GUID + `",
     "base": {"local_id": 13, "enabled": true},
     "texture": "00000000-0000-0000-0000-000000000000", "color": [0, 1, 0, 1]}
  ]
}`
	testing.expect(t, os.write_entire_file(x_path, transmute([]byte)x_json) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	x_guid, gok := engine.asset_db_get_guid(x_path)
	testing.expect(t, gok, "x.scene registered")

	// Two additive copies of X share the pools with the base scene.
	x1 := engine.scene_load_additive_path(x_path)
	testing.expect(t, x1 != nil, "x1 loads")
	x2 := engine.scene_load_additive_path(x_path)
	testing.expect(t, x2 != nil, "x2 loads")
	if x1 == nil || x2 == nil do return
	defer engine.sm_scene_destroy_or_unload(x2)

	before, bok := engine.scene_serialize(x2)
	testing.expect(t, bok, "serialize x2 before churn")
	defer delete(before)

	// Unload x1 → its transform and component slots recycle. Instantiating X
	// into the base scene fills those recycled slots with new content.
	engine.sm_scene_destroy_or_unload(x1)
	spawnH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(x_guid), engine.Transform_Handle(tc.scene.root.handle))
	testing.expect(t, spawnH != {}, "X instantiates into recycled slots")

	after, aok := engine.scene_serialize(x2)
	testing.expect(t, aok, "serialize x2 after churn")
	defer delete(after)
	testing.expect(t, string(before) == string(after),
		"x2 bytes must survive x1 unload + slot reuse")

	// The survivor still carries exactly its two component records.
	testing.expect_value(t, strings.count(string(after), SPRITE_GUID), 2)
}

// The duplicate-scene-after-reopen bug, distilled. Preview/thumbnail worlds
// destroy transforms every render, and pool handles are (index, generation)
// VALUES with no world in them — two fresh pools hand out the SAME handles,
// so a preview-world handle collides with the live scene's root handle.
// Resolving "was this some scene's root?" through the GLOBAL active scene
// then cleared the LIVE scene's root from a preview teardown: scene_destroy
// found no root, leaked every transform, and the next load put a second copy
// beside them — two scenes rendering, one in the hierarchy.
@(test)
test_foreign_world_destroy_keeps_live_root :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	live := tc.scene
	engine.sm_scene_set_active(live)
	target := live.root.handle
	lids_before := len(live.local_ids.forward)

	// A second world with its own scene — the preview world\'s shape. The
	// engine must be safe even without the editor bracket\'s active-scene
	// blinding, so the active scene deliberately stays the LIVE one.
	pv := new(engine.World)
	defer free(pv)
	engine.w_init(pv)
	defer engine.world_destroy_all(pv)
	uc := engine.ctx_get()
	prev := uc.world
	uc.world = pv

	pv_scene := engine.scene_new()
	engine.scene_ensure_root(pv_scene)

	// Both roots are their world\'s first pool slot: the handle VALUES
	// collide. If pool internals ever change allocation order, this premise
	// check fails loudly — reconstruct the collision, do not delete the test.
	testing.expect(t, pv_scene.root.handle == target,
		"premise: fresh worlds hand out colliding handles")

	// The thumbnail teardown: a parentless destroy in the foreign world.
	engine.transform_destroy(engine.Transform_Handle(pv_scene.root.handle))
	engine.scene_destroy(pv_scene)
	uc.world = prev

	testing.expect(t, live.root.handle == target,
		"a preview-world destroy must never clear the live scene\'s root")
	testing.expect(t, engine.pool_valid(&tc.world.transforms, live.root.handle),
		"the live root transform is untouched")
	testing.expect_value(t, len(live.local_ids.forward), lids_before)
}

// scene_destroy must leave NOTHING of its scene in the world, root Ref or
// not. A cleared root used to skip teardown entirely: the transforms kept
// rendering with a dangling scene pointer, no hierarchy listed them, and
// the next Scene allocation reusing the address adopted them as duplicates.
@(test)
test_scene_destroy_sweeps_rootless_content :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	engine.asset_db_init("moonhug/packages/app/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	baseline := 0
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _ in engine.pool_next(&it) do baseline += 1
	}

	s := engine.scene_load_additive_path("moonhug/packages/app/assets/demo_prefabs/bullet.scene")
	testing.expect(t, s != nil, "scene loads")
	if s == nil do return

	// The damage any root-clearing bug inflicts, applied directly.
	engine.scene_clear_root(s)
	engine.sm_scene_unload(s)

	after := 0
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _ in engine.pool_next(&it) do after += 1
	}
	testing.expect_value(t, after, baseline)
}

// Asset-namespace PPtrs must survive nested-instance lid composition. A PPtr
// with a guid addresses ANOTHER asset's namespace (MeshFilter.mesh's local_id
// is a mesh PART id) — the instance remap walker used to push it through the
// scene lid map, so a part id that collided with a source object lid got
// retargeted at a nonexistent part and the filter drew nothing. BoxAnimated
// is the live case: part id 2 == the prefab root's lid 2, so nesting it in
// demo_prefabs broke exactly the outer box.
@(test)
test_nested_instance_keeps_asset_pptr_part_ids :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	engine.asset_db_init("moonhug/packages/app/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	s := engine.scene_load_additive_path("moonhug/packages/app/assets/demo_prefabs/demo_prefabs.scene")
	testing.expect(t, s != nil, "demo_prefabs loads")
	if s == nil do return

	checked := 0
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		if tr.name != "node_2" && tr.name != "node_3" do continue
		th := ih
		th.type_key = .Transform
		_, mf := engine.transform_get_comp(engine.Transform_Handle(th), engine.MeshFilter)
		if mf == nil do continue
		checked += 1
		expected := engine.Local_ID(tr.name == "node_2" ? 1 : 2)
		testing.expectf(t, mf.mesh.local_id == expected,
			"%s: part id must stay %d (authored), got %d — the remap walker corrupted an asset PPtr",
			tr.name, expected, mf.mesh.local_id)
		_, ok := engine.mesh_filter_part(mf)
		testing.expectf(t, ok, "%s: part must resolve in the model's table", tr.name)
	}
	testing.expect_value(t, checked, 2)
}
