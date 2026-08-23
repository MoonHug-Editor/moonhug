package tests

// Hermetic prefab-chain fixtures. Tests that exercise nesting, variants and
// override capture author this chain with engine APIs into a per-test temp
// dir — no test reads shipped package assets (those move and get edited, so
// tests against them drift; a fixture is stable and self-describing).
//
//   c.scene         CRoot > C [SpriteRenderer, FIXTURE_COLOR_BASE]
//   c_Variant       variant of c (scene_create_variant_file)
//   bullet.scene    BRoot > [c_Variant instance, A, B]
//   bullet_Variant  variant of bullet, carrying a DEEP override on its root
//                   variant NS: the inherited C sprite color =
//                   FIXTURE_COLOR_DEEP (authored the editor way — open the
//                   variant, edit the inherited sprite, save)
//   host.scene      HRoot > bullet_Variant instance
//
// c.scene is raw JSON with a MINIMAL sprite record (texture + color only):
// prefabs authored before a component gained fields omit those keys, and the
// save-time capture diff must not read the omissions as overrides. Keep it
// minimal — that gap is what the spurious-override regression test needs.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"

FIXTURE_SPRITE_GUID :: "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"
FIXTURE_COLOR_BASE :: [4]f32{0.5, 0, 0, 1}
FIXTURE_COLOR_DEEP :: [4]f32{0, 1, 1, 0.686}

Fixture_Chain :: struct {
	dir:                                              string,
	c_path, cv_path, bullet_path, bv_path, host_path: string,
	cv_guid, bv_guid:                                 engine.Asset_GUID,
	db_ready:                                         bool,
}

// A loadable one-transform scene, for tests that need a fresh empty host.
fixture_write_empty_scene :: proc(path: string, root_name: string) -> bool {
	j := fmt.tprintf(`{{
  "root": 1,
  "next_local_id": 5,
  "transforms": [
    {{
      "local_id": 1, "name": "%s", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": []
    }}
  ],
  "nested_scenes": [], "breadcrumbs": [], "components": []
}}`, root_name)
	return os.write_entire_file(path, transmute([]byte)j) == nil
}

// First SpriteRenderer in `s` (optionally only on nested-owned/inherited
// content), with its owning transform.
fixture_find_sprite :: proc(w: ^engine.World, s: ^engine.Scene, nested_only := false) -> (^engine.SpriteRenderer, engine.Transform_Handle) {
	it := engine.pool_iterator(&w.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		if nested_only && !tr.nested_owned do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil do return sr, h
	}
	return nil, {}
}

fixture_color_close :: proc(a, b: [4]f32) -> bool {
	d := a - b
	return d.x * d.x + d.y * d.y + d.z * d.z + d.w * d.w < 0.0001
}

// Builds the chain. Call AFTER setup(tc) — authoring runs through the live
// world. Owns asset_db_init on the temp dir, so the test must not init its
// own. Leaves the HOST loaded as the active scene (tc.scene).
fixture_chain_author :: proc(t: ^testing.T, tc: ^TestCtx, dir: string) -> (fx: Fixture_Chain, ok: bool) {
	os.make_directory(dir)
	fx.dir = dir
	fx.c_path = strings.concatenate({dir, "/c.scene"}, context.temp_allocator)
	fx.cv_path = strings.concatenate({dir, "/c_Variant.scene"}, context.temp_allocator)
	fx.bullet_path = strings.concatenate({dir, "/bullet.scene"}, context.temp_allocator)
	fx.bv_path = strings.concatenate({dir, "/bullet_Variant.scene"}, context.temp_allocator)
	fx.host_path = strings.concatenate({dir, "/host.scene"}, context.temp_allocator)

	c_json := `{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {
      "local_id": 1, "name": "CRoot", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [{"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}],
      "components": []
    },
    {
      "local_id": 2, "name": "C", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": [{"local_id": 3}]
    }
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "` + FIXTURE_SPRITE_GUID + `",
     "base": {"local_id": 3, "enabled": true},
     "texture": "00000000-0000-0000-0000-000000000000",
     "color": [0.5, 0, 0, 1]}
  ]
}`
	if os.write_entire_file(fx.c_path, transmute([]byte)c_json) != nil {
		testing.expect(t, false, "fixture: write c.scene")
		return fx, false
	}

	engine.asset_db_init(dir)
	fx.db_ready = true

	// c_Variant: variant of c.
	if !engine.scene_create_variant_file(fx.c_path, fx.cv_path) {
		testing.expect(t, false, "fixture: create c_Variant")
		return fx, false
	}
	asset_pipeline.asset_db_refresh()
	cv_guid, cvok := engine.asset_db_get_guid(fx.cv_path)
	testing.expect(t, cvok, "fixture: c_Variant registered")
	if !cvok do return fx, false
	fx.cv_guid = engine.Asset_GUID(cv_guid)

	// bullet: authored in the bootstrap scene — c_Variant instance, then two
	// plain children so root child order is testable.
	root := engine.Transform_Handle(tc.scene.root.handle)
	if engine.scene_instantiate_guid_nested(fx.cv_guid, root) == {} {
		testing.expect(t, false, "fixture: nest c_Variant into bullet")
		return fx, false
	}
	engine.transform_new("A", root)
	engine.transform_new("B", root)
	if !engine.scene_save(tc.scene, fx.bullet_path) {
		testing.expect(t, false, "fixture: save bullet")
		return fx, false
	}
	asset_pipeline.asset_db_refresh()

	// bullet_Variant: variant of bullet.
	if !engine.scene_create_variant_file(fx.bullet_path, fx.bv_path) {
		testing.expect(t, false, "fixture: create bullet_Variant")
		return fx, false
	}
	asset_pipeline.asset_db_refresh()
	bv_guid, bvok := engine.asset_db_get_guid(fx.bv_path)
	testing.expect(t, bvok, "fixture: bullet_Variant registered")
	if !bvok do return fx, false
	fx.bv_guid = engine.Asset_GUID(bv_guid)

	// The deep override, authored the editor way: open the variant, edit the
	// INHERITED sprite (nested-owned content from c via bullet), save — the
	// capture lands on the variant's root NS.
	bv := engine.scene_load_single_path(fx.bv_path)
	testing.expect(t, bv != nil, "fixture: bullet_Variant loads")
	if bv == nil do return fx, false
	tc.scene = bv
	engine.sm_scene_set_active(bv)
	sr, _ := fixture_find_sprite(&tc.world, bv, nested_only = true)
	testing.expect(t, sr != nil, "fixture: inherited sprite in bullet_Variant")
	if sr == nil do return fx, false
	sr.color = FIXTURE_COLOR_DEEP
	if !engine.scene_save(bv, fx.bv_path) {
		testing.expect(t, false, "fixture: save bullet_Variant override")
		return fx, false
	}

	// host: nests bullet_Variant.
	if !fixture_write_empty_scene(fx.host_path, "HRoot") {
		testing.expect(t, false, "fixture: write host")
		return fx, false
	}
	asset_pipeline.asset_db_refresh()
	host := engine.scene_load_single_path(fx.host_path)
	testing.expect(t, host != nil, "fixture: host loads")
	if host == nil do return fx, false
	tc.scene = host
	engine.sm_scene_set_active(host)
	if engine.scene_instantiate_guid_nested(fx.bv_guid, engine.Transform_Handle(host.root.handle)) == {} {
		testing.expect(t, false, "fixture: nest bullet_Variant into host")
		return fx, false
	}
	if !engine.scene_save(host, fx.host_path) {
		testing.expect(t, false, "fixture: save host")
		return fx, false
	}
	return fx, true
}

// Pairs with fixture_chain_author. Defer BEFORE setup/teardown so it runs
// after teardown (LIFO), matching the asset_db/scene_lib shutdown order every
// other test uses.
fixture_chain_destroy :: proc(fx: ^Fixture_Chain) {
	if fx.db_ready {
		engine.asset_db_shutdown()
		engine.scene_lib_shutdown()
	}
	if fx.dir == "" do return
	for p in ([]string{fx.c_path, fx.cv_path, fx.bullet_path, fx.bv_path, fx.host_path}) {
		if p == "" do continue
		os.remove(p)
		os.remove(strings.concatenate({p, ".meta"}, context.temp_allocator))
	}
	os.remove(fx.dir)
}
