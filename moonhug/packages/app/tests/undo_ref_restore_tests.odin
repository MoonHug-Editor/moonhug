package app_tests

// Deleting a referenced transform and undoing the delete must re-resolve refs
// held by components OUTSIDE the restored subtree. Repro: open tank.scene,
// delete Turret — the Tank component on Root dangles (correct, the target is
// gone) — undo: the Turret subtree is restored with its original lids and the
// Tank's turret ref must bind to the NEW live handle.

import app ".."
import undo "moonhug:editor/undo"
import "moonhug:engine"
import common "moonhug:tests/common"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_undo_delete_restores_refs_outside_subtree :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_undo_outside_ref"
	os.make_directory(dir)
	path := strings.concatenate({dir, "/tank.scene"}, context.temp_allocator)
	meta := strings.concatenate({dir, "/tank.scene.meta"}, context.temp_allocator)
	defer { os.remove(path); os.remove(meta); os.remove(dir) }

	scene_json := fmt.tprintf(`{{
  "root": 1,
  "transforms": [
    {{"local_id": 1, "name": "Root", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [{{"pptr": {{"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}}}],
      "components": [{{"local_id": 11}}]}},
    {{"local_id": 2, "name": "Turret", "is_active": true,
      "position": [0,1,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []}}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 11, "enabled": true}},
      "turret": {{"local_id": 2}}}}
  ]
}}`, TANK_TYPE_GUID)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)scene_json) == nil)
	testing.expect(t, os.write_entire_file(meta, transmute([]byte)string(`{"guid": "abcd1234-0000-4000-8000-0000000000a1"}`)) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc, "")
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer { undo.destroy(s); free(s) }

	loaded := engine.scene_load_single_path(path)
	testing.expect(t, loaded != nil, "scene loads")
	if loaded == nil do return
	tc.scene = loaded
	engine.sm_scene_set_active(loaded)

	w := engine.ctx_world()
	turret_h, tok := engine.bimap_get(&loaded.local_ids, engine.Local_ID(2))
	testing.expect(t, tok, "turret lid registered")
	if !tok do return

	find_tank :: proc(w: ^engine.World) -> ^app.Tank {
		pool := app.tanks(w)
		if pool == nil do return nil
		for i in 0 ..< len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}
	tank := find_tank(w)
	testing.expect(t, tank != nil, "Tank component loaded")
	if tank == nil do return
	testing.expect(t, tank.turret.handle == turret_h, "turret ref starts resolved")

	// Delete Turret (the editor's delete flow: capture, destroy, commit).
	pre, pok := undo.record_delete_pre(engine.Transform_Handle(turret_h))
	testing.expect(t, pok, "delete_pre captured")
	defer if pok do undo.record_cleanup(&pre)
	engine.transform_destroy(engine.Transform_Handle(turret_h))
	undo.record_commit(&pre)

	testing.expect(t, !engine.pool_valid(&w.transforms, tank.turret.handle),
		"ref dangles while the target is deleted")

	// Undo: subtree restored with lid 2 — the Tank's ref must bind LIVE again.
	testing.expect(t, undo.apply_undo(s), "undo succeeded")

	restored_h, rok := undo.scene_find_transform_by_local_id(loaded, 2)
	testing.expect(t, rok, "turret restored under its recorded lid")
	tank2 := find_tank(w)
	testing.expect(t, tank2 != nil)
	if tank2 == nil do return
	testing.expect_value(t, tank2.turret.local_id, engine.Local_ID(2))
	testing.expect(t, tank2.turret.handle == restored_h && engine.pool_valid(&w.transforms, tank2.turret.handle),
		"turret ref must re-resolve to the restored transform")
}

// Multi-object delete as ONE undo group, with a ref crossing between the two
// deleted subtrees: A's Tank references sibling B. Deletes are recorded
// B-then-A, so group revert restores A FIRST — its ref to B is dead at that
// moment and only the scene-wide rebind after B's restore can bind it.
@(test)
test_undo_group_delete_restores_cross_subtree_refs :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_undo_group_ref"
	os.make_directory(dir)
	path := strings.concatenate({dir, "/s.scene"}, context.temp_allocator)
	meta := strings.concatenate({dir, "/s.scene.meta"}, context.temp_allocator)
	defer { os.remove(path); os.remove(meta); os.remove(dir) }

	scene_json := fmt.tprintf(`{{
  "root": 1,
  "transforms": [
    {{"local_id": 1, "name": "Root", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [
        {{"pptr": {{"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}}},
        {{"pptr": {{"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}}}
      ],
      "components": []}},
    {{"local_id": 2, "name": "A", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": [{{"local_id": 11}}]}},
    {{"local_id": 3, "name": "B", "is_active": true,
      "position": [1,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []}}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 11, "enabled": true}},
      "turret": {{"local_id": 3}}}}
  ]
}}`, TANK_TYPE_GUID)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)scene_json) == nil)
	testing.expect(t, os.write_entire_file(meta, transmute([]byte)string(`{"guid": "abcd1234-0000-4000-8000-0000000000a2"}`)) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc, "")
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer { undo.destroy(s); free(s) }

	loaded := engine.scene_load_single_path(path)
	testing.expect(t, loaded != nil, "scene loads")
	if loaded == nil do return
	tc.scene = loaded
	engine.sm_scene_set_active(loaded)

	w := engine.ctx_world()
	aH, aok := engine.bimap_get(&loaded.local_ids, engine.Local_ID(2))
	bH, bok := engine.bimap_get(&loaded.local_ids, engine.Local_ID(3))
	testing.expect(t, aok && bok, "lids registered")
	if !aok || !bok do return

	find_tank :: proc(w: ^engine.World) -> ^app.Tank {
		pool := app.tanks(w)
		if pool == nil do return nil
		for i in 0 ..< len(pool.slots) {
			if pool.slots[i].alive do return &pool.slots[i].data
		}
		return nil
	}
	tank := find_tank(w)
	testing.expect(t, tank != nil, "Tank on A loaded")
	if tank == nil do return
	testing.expect(t, tank.turret.handle == bH, "cross-subtree ref starts resolved")

	// Editor multi-delete: one group, B recorded first so revert restores the
	// ref-HOLDER (A) before its target (B) — the adversarial order.
	g := undo.group_begin("Delete Selected")
	undo.record_delete(engine.Transform_Handle(bH))
	undo.record_delete(engine.Transform_Handle(aH))
	undo.group_commit(&g)
	undo.group_end(&g)

	testing.expect(t, find_tank(w) == nil, "Tank gone with A")

	testing.expect(t, undo.apply_undo(s), "group undo succeeded")

	restored_b, rbok := undo.scene_find_transform_by_local_id(loaded, 3)
	testing.expect(t, rbok, "B restored under its lid")
	tank2 := find_tank(w)
	testing.expect(t, tank2 != nil, "Tank restored with A")
	if tank2 == nil do return
	testing.expect_value(t, tank2.turret.local_id, engine.Local_ID(3))
	testing.expect(t, tank2.turret.handle == restored_b && engine.pool_valid(&w.transforms, tank2.turret.handle),
		"cross-subtree ref must re-resolve after group undo")
}
