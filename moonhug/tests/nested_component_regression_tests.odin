package tests

import "core:os"
import "core:fmt"
import "core:strings"
import "core:testing"
import "../engine"
import common "common"

// Saving an UNCHANGED nested scene must not invent overrides. A prefab authored
// before a component gained a field omits that key on disk, but the live struct
// always serializes it — the capture diff must normalize the prefab base to the
// live struct's field set, or every such field is captured as a false override.
// (tank_demo nests tank; tank's SpriteRenderers predate material/sort keys.)
@(test)
test_nested_save_no_spurious_overrides :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	src := "moonhug/assets/demo_tank/tank_demo.scene"
	tmp := "moonhug/assets/_test_tank_demo_rt.scene"
	defer os.remove(tmp)
	{
		data, rerr := os.read_entire_file(src, context.temp_allocator)
		testing.expect(t, rerr == nil, "read source")
		if rerr == nil do _ = os.write_entire_file(tmp, data)
	}

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := engine.scene_load_single_path(tmp)
	testing.expect(t, s != nil, "load")
	if s == nil do return
	tc.scene = s
	engine.sm_scene_set_active(s)

	before := 0
	for &ns in s.nested_scenes do before += len(ns.overrides)

	testing.expect(t, engine.scene_save(s, tmp), "save")

	after := 0
	for &ns in s.nested_scenes {
		for ov in ns.overrides {
			fmt.printf("[overrides]   target.lid=%d path=%s\n", ov.target.local_id, ov.property_path)
			after += 1
		}
	}
	testing.expect(t, after == before,
		fmt.tprintf("spurious overrides captured on unchanged save: %d -> %d", before, after))
}

// A component whose registered type can't parse the record (corrupt/incompatible
// field) must be PRESERVED verbatim, never silently dropped. Also covers the
// unknown-type-guid case: both go through _stash_unknown_component.
@(test)
test_unparseable_component_preserved :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_unparseable"
	os.make_directory(dir)
	path := strings.concatenate({dir, "/s.scene"}, context.temp_allocator)
	meta := strings.concatenate({dir, "/s.scene.meta"}, context.temp_allocator)
	defer { os.remove(path); os.remove(meta); os.remove(dir) }

	// SpriteRenderer(10) with a MALFORMED texture (not a guid) — registered type,
	// but the record won't parse. Plus a genuinely unknown type(11).
	SPRITE_GUID :: "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"
	FAKE_GUID :: "deadbeef-0000-4000-8000-000000000042"
	scene_json := fmt.tprintf(`{{
  "root": 1, "next_local_id": 20,
  "transforms": [
    {{"local_id": 1, "name": "Root", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": [{{"local_id": 10}}, {{"local_id": 11}}]}}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 10, "enabled": true}}, "texture": "not-a-guid", "color": [1,0,0,1]}},
    {{"__type": "%s", "base": {{"local_id": 11, "enabled": true}}, "mystery": 7}}
  ]
}}`, SPRITE_GUID, FAKE_GUID)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)scene_json) == nil)
	testing.expect(t, os.write_entire_file(meta, transmute([]byte)string(`{"guid": "abcd1234-0000-4000-8000-000000000002"}`)) == nil)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := engine.scene_load_single_path(path)
	testing.expect(t, s != nil, "load")
	if s == nil do return
	tc.scene = s

	// Both records are unresolvable-into-type here → both stashed.
	testing.expect_value(t, len(s.unknown_components), 2)

	testing.expect(t, engine.scene_save(s, path), "save")
	saved, _ := os.read_entire_file(path, context.temp_allocator)

	testing.expect(t, strings.contains(string(saved), "not-a-guid"),
		"unparseable-but-registered component must survive verbatim")
	testing.expect(t, strings.contains(string(saved), "mystery"),
		"unknown-type component must survive verbatim")
}

// EXACT editor repro: tank_demo (which NESTS tank) is open first — the editor
// auto-loads it from settings. The user then opens tank.scene directly
// (single load unloads tank_demo) and saves. Components must survive.
@(test)
test_open_host_then_open_prefab_and_save :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tank_src := "moonhug/assets/demo_tank/tank.scene"
	tmp := "moonhug/assets/demo_tank/_test_tank_copy.scene"
	defer os.remove(tmp)

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Step 1: open tank_demo (host that nests tank + tank_projectile).
	host := engine.scene_load_single_path("moonhug/assets/demo_tank/tank_demo.scene")
	testing.expect(t, host != nil, "tank_demo should load")
	if host == nil do return
	tc.scene = host
	engine.sm_scene_set_active(host)

	// Step 2: open tank.scene directly (unloads tank_demo), save to tmp.
	s := engine.scene_load_single_path(tank_src)
	testing.expect(t, s != nil, "tank should load")
	if s == nil do return
	tc.scene = s
	engine.sm_scene_set_active(s)

	testing.expect(t, engine.scene_save(s, tmp), "save")
	saved, _ := os.read_entire_file(tmp, context.temp_allocator)
	n_sprites := strings.count(string(saved), "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f")
	n_tank := strings.count(string(saved), "f15b003c-a491-4aec-b838-49e641a25346")
	fmt.printf("[REPRO] saved sprites=%d tank=%d\n", n_sprites, n_tank)
	testing.expect_value(t, n_sprites, 3)
	testing.expect_value(t, n_tank, 1)
}
