package engine_tests

// Asset preload and scene_load_async. host.scene nests inner.scene, whose
// MeshRenderer names three assets: a material record of its own file, a
// material file, and a file of a type only this test loads (.zzpre).

import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine"

@(private = "file")
_INNER_FMT :: `{{
  "root": 1,
  "transforms": [
    {{"local_id": 1, "name": "Inner", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
     "children": [], "components": [{{"local_id": 3}}]}}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "73e161a0-c599-4cfb-9826-447e05baa76c",
     "base": {{"local_id": 3, "enabled": true}},
     "materials": [
       {{"local_id": 77, "guid": "00000000-0000-0000-0000-000000000000"}},
       "%s",
       "%s"
     ]}}
  ],
  "assets": [{{"local_id": 77, "type": "mat", "name": "Green", "data": {{"color": [0, 1, 0, 1]}}}}]
}}`

@(private = "file")
_Files :: struct {
	host:                             string,
	inner_guid, stone_guid, zz_guid: engine.Asset_GUID,
}

@(private = "file")
_zz_loaded: [dynamic]engine.PPtr

@(private = "file")
_zz_preload :: proc(ref: engine.PPtr) {
	append(&_zz_loaded, ref)
}

@(private = "file")
_author :: proc(t: ^testing.T, tc: ^TestCtx, dir: string) -> (f: _Files, ok: bool) {
	path :: proc(dir, name: string) -> string {
		return strings.concatenate({dir, "/", name}, context.temp_allocator)
	}
	guid_of :: proc(t: ^testing.T, p: string) -> (engine.Asset_GUID, bool) {
		raw, known := engine.asset_db_get_guid(p)
		testing.expectf(t, known, "%s is in the asset db", p)
		return engine.Asset_GUID(raw), known
	}
	os.make_directory(dir)
	if !testing.expect(t, os.write_entire_file(path(dir, "stone.mat"), transmute([]byte)string(`{"color": [1, 0, 0, 1]}`)) == nil) do return
	if !testing.expect(t, os.write_entire_file(path(dir, "thing.zzpre"), transmute([]byte)string("x")) == nil) do return
	engine.asset_db_init(dir)
	asset_pipeline.asset_db_refresh()
	f.stone_guid = guid_of(t, path(dir, "stone.mat")) or_return
	f.zz_guid = guid_of(t, path(dir, "thing.zzpre")) or_return

	inner := fmt.tprintf(_INNER_FMT,
		uuid.to_string(uuid.Identifier(f.stone_guid), context.temp_allocator),
		uuid.to_string(uuid.Identifier(f.zz_guid), context.temp_allocator))
	if !testing.expect(t, os.write_entire_file(path(dir, "inner.scene"), transmute([]byte)inner) == nil) do return
	asset_pipeline.asset_db_refresh()
	f.inner_guid = guid_of(t, path(dir, "inner.scene")) or_return

	// host: the bootstrap scene with inner nested, saved.
	f.host = path(dir, "host.scene")
	if !testing.expect(t, engine.scene_instantiate_guid_nested(f.inner_guid, engine.Transform_Handle(tc.scene.root.handle)) != {}, "inner nests into host") do return
	if !testing.expect(t, engine.scene_save(tc.scene, f.host), "host saves") do return
	asset_pipeline.asset_db_refresh()
	return f, true
}

@(private = "file")
_has :: proc(list: []engine.PPtr, ref: engine.PPtr) -> bool {
	for r in list do if r == ref do return true
	return false
}

@(private = "file")
_renderer_count :: proc(tc: ^TestCtx, s: ^engine.Scene) -> int {
	n := 0
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		th := ih
		th.type_key = .Transform
		_, mr := engine.transform_get_comp(engine.Transform_Handle(th), engine.MeshRenderer)
		if mr != nil do n += 1
	}
	return n
}

// The walk lists a nested prefab as a scene to open, and lists a sub-asset of
// the file, a file by guid and nothing else: no type guid, no object.
@(test)
test_scene_file_asset_refs_lists_files_sub_assets_and_nested_prefabs :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	dir :: "moonhug/tests/fixtures/_scene_load_refs_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	f, ok := _author(t, tc, dir)
	if !ok do return

	refs: engine.Scene_Asset_Refs
	refs.assets = make([dynamic]engine.PPtr, context.temp_allocator)
	refs.scenes = make([dynamic]engine.Asset_GUID, context.temp_allocator)

	host, host_ok := engine.scene_file_load(f.host)
	if !testing.expect(t, host_ok, "host parses") do return
	defer engine.scene_file_destroy(&host)
	host_raw, _ := engine.asset_db_get_guid(f.host)
	engine.scene_file_asset_refs(&host, engine.Asset_GUID(host_raw), &refs)
	testing.expectf(t, len(refs.scenes) == 1 && refs.scenes[0] == f.inner_guid, "host names inner as its one nested prefab, got %v", refs.scenes)

	inner, inner_ok := engine.scene_file_load(strings.concatenate({dir, "/inner.scene"}, context.temp_allocator))
	if !testing.expect(t, inner_ok, "inner parses") do return
	defer engine.scene_file_destroy(&inner)
	engine.scene_file_asset_refs(&inner, f.inner_guid, &refs)
	// An override record in host can name the same assets: each is listed once.
	testing.expectf(t, len(refs.assets) == 3, "three assets in all, got %v", refs.assets)
	testing.expect(t, _has(refs.assets[:], engine.PPtr{guid = f.inner_guid, local_id = 77}), "the record of inner's own file")
	testing.expect(t, _has(refs.assets[:], engine.PPtr{guid = f.stone_guid}), "the material file")
	testing.expect(t, _has(refs.assets[:], engine.PPtr{guid = f.zz_guid}), "the .zzpre file")

	// A second walk of the same file adds nothing.
	engine.scene_file_asset_refs(&inner, f.inner_guid, &refs)
	testing.expectf(t, len(refs.assets) == 3 && len(refs.scenes) == 1, "a second walk adds nothing")
}

// Outside a running game no frame runs the loads: the scene is loaded, and
// the assets of its nested prefab preloaded, when the call returns.
@(test)
test_scene_load_async_outside_a_game_loads_before_it_returns :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	dir :: "moonhug/tests/fixtures/_scene_load_sync_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	f, ok := _author(t, tc, dir)
	if !ok do return
	engine.asset_preload_add("zzpre", _zz_preload)
	_zz_loaded = make([dynamic]engine.PPtr, context.temp_allocator)

	// A prefab by hand: its assets load.
	testing.expect(t, engine.asset_preload(engine.PPtr{guid = f.inner_guid}), "a prefab preloads")
	testing.expectf(t, len(_zz_loaded) == 1, "the prefab's .zzpre file loads, got %v", _zz_loaded)
	clear(&_zz_loaded)

	h := engine.scene_load_async(f.host)
	testing.expect(t, engine.scene_load_done(h), "done at return")
	testing.expect(t, engine.scene_load_progress(h) == 1)
	s := engine.scene_load_scene(h)
	if !testing.expect(t, s != nil, "the scene is loaded") do return
	tc.scene = s
	testing.expectf(t, _renderer_count(tc, s) == 1, "inner's renderer is in the scene")
	testing.expectf(t, len(_zz_loaded) == 1 && _zz_loaded[0] == engine.PPtr{guid = f.zz_guid}, "the .zzpre file preloads once, got %v", _zz_loaded)

	missing := engine.scene_load_async(strings.concatenate({dir, "/nope.scene"}, context.temp_allocator), additive = true)
	testing.expect(t, engine.scene_load_done(missing) && engine.scene_load_scene(missing) == nil, "a missing file ends the load with no scene")
}

// In a running game the load advances one piece per step, holds before it
// creates the scene when asked to, and finishes after scene_load_activate.
@(test)
test_scene_load_async_in_a_game_runs_over_steps_and_holds_activation :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	dir :: "moonhug/tests/fixtures/_scene_load_steps_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	f, ok := _author(t, tc, dir)
	if !ok do return
	engine.asset_preload_add("zzpre", _zz_preload)
	_zz_loaded = make([dynamic]engine.PPtr, context.temp_allocator)

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)

	h := engine.scene_load_async(f.host, additive = true, activate = false)
	testing.expect(t, !engine.scene_load_done(h) && engine.scene_load_progress(h) == 0, "nothing runs in the call")

	// A budget of 0 runs one piece per step.
	last := f32(0)
	steps := 0
	for !engine.scene_load_ready(h) && steps < 64 {
		engine.scene_loads_step(0)
		steps += 1
		p := engine.scene_load_progress(h)
		testing.expectf(t, p >= last, "progress never goes back: %v after %v", p, last)
		last = p
	}
	testing.expectf(t, engine.scene_load_ready(h), "the load reaches its hold, after %d steps", steps)
	testing.expectf(t, steps > 3, "the work is spread over steps, got %d", steps)
	testing.expectf(t, len(_zz_loaded) == 1, "the assets are loaded at the hold, got %v", _zz_loaded)
	testing.expect(t, last < 1 && !engine.scene_load_done(h) && engine.scene_load_scene(h) == nil, "no scene yet")

	// Held: more steps change nothing.
	engine.scene_loads_step(0)
	testing.expect(t, engine.scene_load_ready(h), "still on hold")

	engine.scene_load_activate(h)
	for _ in 0 ..< 4 do engine.scene_loads_step(0)
	testing.expect(t, engine.scene_load_done(h) && engine.scene_load_progress(h) == 1, "done after activate")
	s := engine.scene_load_scene(h)
	if !testing.expect(t, s != nil, "the scene is loaded") do return
	testing.expect(t, s != tc.scene && engine.sm_scene_is_loaded(tc.scene), "additive: the first scene stays")
	testing.expectf(t, _renderer_count(tc, s) == 1, "inner's renderer is in the new scene")
}
