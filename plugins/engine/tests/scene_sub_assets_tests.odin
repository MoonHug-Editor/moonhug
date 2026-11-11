package engine_tests

// A scene file's sub-assets (plugins/engine/scene_sub_assets.odin): a scene file holds
// asset records, a reference names one as {file guid, local id}, written with
// an empty guid inside the file itself, and a loader reads the record through
// asset_source. A nested prefab's records stay with the prefab's file and
// every instance shares them.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:libs/catalog"
import ser "moonhug:libs/serialization"
import "moonhug:packages/engine"

@(private = "file")
_MESH_RENDERER_GUID :: "73e161a0-c599-4cfb-9826-447e05baa76c"

@(test)
test_scene_sub_asset_material_loads_and_round_trips :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "moonhug/tests/fixtures/_test_scene_sub_asset_material.scene")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	tH := engine.transform_new("Cube")
	engine.scene_set_root(tc.scene, tH)
	_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
	if !testing.expect(t, mr != nil) do return

	ref, added := engine.scene_sub_asset_add(tc.scene, "mat", `{"color":[1,0,0,1]}`)
	if !testing.expect(t, added, "the material is added to the scene") do return
	testing.expect(t, ref.local_id != 0, "it has a local id")
	append(&mr.materials, ref)

	// A loader reads it through its key, as it reads a file's.
	mat, loaded := engine.material_load(engine.asset_key(ref))
	testing.expect(t, loaded && mat.color == {1, 0, 0, 1}, "the scene's material loads")

	testing.expect(t, engine.scene_save(tc.scene, tc.path), "the scene saves")
	text, rerr := os.read_entire_file(tc.path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect(t, strings.contains(string(text), `"assets"`), "the file holds the record")
	testing.expect(t, strings.contains(string(text), `"type": "mat"`), "with its type")

	scene := engine.scene_load_single_path(tc.path)
	if !testing.expect(t, scene != nil, "the scene loads") do return
	tc.scene = scene
	testing.expect_value(t, len(scene.assets), 1)
	_, lmr := engine.transform_get_comp(engine.Transform_Handle(scene.root.handle), engine.MeshRenderer)
	if !testing.expect(t, lmr != nil && len(lmr.materials) == 1, "the reference survives") do return
	testing.expect_value(t, lmr.materials[0].local_id, ref.local_id)

	engine.material_cache_shutdown()
	engine.material_cache_init()
	mat, loaded = engine.material_load(engine.asset_key(lmr.materials[0]))
	testing.expect(t, loaded && mat.color == {1, 0, 0, 1}, "the reloaded scene's material loads from its record")

	// New data under the same reference.
	testing.expect(t, engine.scene_sub_asset_set(scene, ref.local_id, `{"color":[0,0,1,1]}`))
	engine.material_unload(engine.asset_key(lmr.materials[0]))
	mat, loaded = engine.material_load(engine.asset_key(lmr.materials[0]))
	testing.expect(t, loaded && mat.color == {0, 0, 1, 1}, "an edited record is what loads next")
}

// A prefab file with a material of its own and a guid-only material written
// the way files before this hold it. Opened by itself, its reference names
// the prefab's file. Nested twice, both instances name that same file and
// record: one shared asset, not one per instance.
@(test)
test_nested_prefab_shares_its_sub_asset_material :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	dir :: "moonhug/tests/fixtures/_scene_sub_assets_tmp"
	prefab :: dir + "/p.scene"
	os.make_directory(dir)
	defer _remove_tree(dir)
	json_text := `{
  "root": 1,
  "transforms": [
    {
      "local_id": 1, "name": "P", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [], "components": [{"local_id": 3}]
    }
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "` + _MESH_RENDERER_GUID + `",
     "base": {"local_id": 3, "enabled": true},
     "materials": [
       {"local_id": 77, "guid": "00000000-0000-0000-0000-000000000000"},
       "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
     ]}
  ],
  "assets": [
    {"local_id": 77, "type": "mat", "data": {"color": [0, 1, 0, 1], "texture": {"local_id": 78, "guid": "00000000-0000-0000-0000-000000000000"}}},
    {"local_id": 78, "type": "noise", "data": {"kind": 2, "frequency": 6}}
  ]
}`
	if !testing.expect(t, os.write_entire_file(prefab, transmute([]byte)string(json_text)) == nil) do return
	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	asset_pipeline.asset_db_refresh()
	guid_raw, known := engine.asset_db_get_guid(prefab)
	if !testing.expect(t, known, "the prefab is in the asset db") do return
	p_guid := engine.Asset_GUID(guid_raw)
	want := engine.PPtr{guid = p_guid, local_id = 77}

	// Nested twice under the bootstrap scene's root.
	root := engine.transform_new("Host")
	engine.scene_set_root(tc.scene, root)
	a := engine.scene_instantiate_guid_nested(p_guid, root)
	b := engine.scene_instantiate_guid_nested(p_guid, root)
	testing.expect(t, a != {} && b != {}, "both instances exist")
	found := 0
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != tc.scene do continue
		th := ih
		th.type_key = .Transform
		_, mr := engine.transform_get_comp(engine.Transform_Handle(th), engine.MeshRenderer)
		if mr == nil do continue
		found += 1
		if !testing.expect(t, len(mr.materials) == 2, "both material slots load") do continue
		testing.expectf(t, mr.materials[0] == want, "an instance's reference names the prefab's file and record, got %v", mr.materials[0])
		testing.expect(t, mr.materials[1].local_id == 0 && mr.materials[1].guid != {}, "a guid-only reference reads as the whole asset")
	}
	testing.expect_value(t, found, 2)

	mat, loaded := engine.material_load(engine.asset_key(want))
	testing.expect(t, loaded && mat.color == {0, 1, 0, 1}, "the prefab's own material loads")
	// The material's own reference names a record of the same file.
	if loaded {
		testing.expectf(t, mat.texture == engine.PPtr{guid = p_guid, local_id = 78}, "that material's texture names the prefab's noise record, got %v", mat.texture)
		testing.expect_value(t, engine.asset_type(engine.asset_key(mat.texture)), "noise")
		data, _, src_ok := engine.asset_source(engine.asset_key(mat.texture))
		n, parsed := engine.noise_map_parse(data)
		testing.expect(t, src_ok && parsed && n.kind == .Cellular && n.frequency == 6 && n.size == engine.NOISE_MAP_DEFAULT.size, "the noise record reads over the defaults")
	}

	// The prefab opened by itself: the same reference.
	p := engine.scene_load_additive_path(prefab)
	if !testing.expect(t, p != nil, "the prefab opens") do return
	_, pmr := engine.transform_get_comp(engine.Transform_Handle(p.root.handle), engine.MeshRenderer)
	if !testing.expect(t, pmr != nil && len(pmr.materials) == 2) do return
	testing.expectf(t, pmr.materials[0] == want, "opened by itself its reference names its own file, got %v", pmr.materials[0])

	// Saved again, the reference is written without the file's guid.
	out, ok := engine.scene_serialize(p)
	testing.expect(t, ok)
	defer delete(out)
	testing.expect(t, strings.contains(string(out), `"local_id": 77`), "the reference is saved")
	testing.expect(t, !strings.contains(string(out), uuid.to_string(guid_raw, context.temp_allocator)), "a reference into the own file is saved without the file's guid")
	testing.expect(t, strings.contains(string(out), `"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"`), "a whole-asset reference is saved as its guid")
}

// A noise map's pixels: the same numbers give the same pixels, every value is
// in range, and the pattern tiles, so the left edge continues at the right.
@(test)
test_noise_map_pixels_are_stable_and_tile :: proc(t: ^testing.T) {
	for kind in engine.Noise_Kind {
		n := engine.NOISE_MAP_DEFAULT
		n.kind = kind
		n.size = 32
		n.seed = 7
		a := engine.noise_map_pixels(n, context.temp_allocator)
		b := engine.noise_map_pixels(n, context.temp_allocator)
		testing.expect_value(t, len(a), 32 * 32 * 4)
		same := true
		for v, i in a do if v != b[i] do same = false
		testing.expectf(t, same, "%v: the same numbers give the same pixels", kind)
		lo, hi := u8(255), u8(0)
		for i := 0; i < len(a); i += 4 {
			lo = min(lo, a[i])
			hi = max(hi, a[i])
		}
		testing.expectf(t, hi > lo + 40, "%v: the pattern has contrast, %d to %d", kind, lo, hi)
		for v in ([]f64{0.1, 0.37, 0.9}) {
			testing.expectf(t, abs(engine.noise_map_value(n, 0, v) - engine.noise_map_value(n, 1, v)) < 0.0001, "%v: the left edge continues at the right", kind)
			testing.expectf(t, abs(engine.noise_map_value(n, v, 0) - engine.noise_map_value(n, v, 1)) < 0.0001, "%v: the top edge continues at the bottom", kind)
		}
	}
	other := engine.NOISE_MAP_DEFAULT
	other.size = 32
	other.seed = 8
	n := engine.NOISE_MAP_DEFAULT
	n.size = 32
	n.seed = 7
	a := engine.noise_map_pixels(n, context.temp_allocator)
	b := engine.noise_map_pixels(other, context.temp_allocator)
	differ := false
	for v, i in a do if v != b[i] do differ = true
	testing.expect(t, differ, "another seed gives another pattern")
}

// A map large enough to be split between threads has every pixel the value
// noise_map_value gives for it: no row is left out or filled twice.
@(test)
test_noise_map_pixels_split_between_threads_match_the_value :: proc(t: ^testing.T) {
	for kind in engine.Noise_Kind {
		n := engine.NOISE_MAP_DEFAULT
		n.kind = kind
		n.size = 200
		n.octaves = 2
		n.seed = 3
		pixels := engine.noise_map_pixels(n, context.temp_allocator)
		wrong := 0
		for y in 0 ..< 200 {
			for x in 0 ..< 200 {
				value := clamp(engine.noise_map_value(n, (f64(x) + 0.5) / 200, (f64(y) + 0.5) / 200), 0, 1)
				if pixels[(y * 200 + x) * 4] != u8(value * 255 + 0.5) do wrong += 1
			}
		}
		testing.expectf(t, wrong == 0, "%v: %d pixels differ from the value at their place", kind, wrong)
	}
}

// The asset database knows a scene file's sub-assets: the scene's list is
// read from it, with no file opened, and follows every change of an open
// scene's records.
@(test)
test_asset_database_lists_an_open_scenes_sub_assets :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "moonhug/tests/fixtures/_test_scene_sub_asset_index.scene")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	// A guid no file has: nothing can be read from disk for it.
	guid := engine.Asset_GUID{0 = 0x5A, 15 = 0x17}
	tc.scene.asset_guid = guid
	defer engine.asset_db_sub_assets_set(guid, nil)

	testing.expect_value(t, len(engine.scene_sub_assets(guid)), 0)
	first, _ := engine.scene_sub_asset_add(tc.scene, "mat", `{}`, "First")
	second, _ := engine.scene_sub_asset_add(tc.scene, "noise", `{}`, "Second")
	list := engine.scene_sub_assets(guid)
	if !testing.expect_value(t, len(list), 2) do return
	testing.expect(t, list[0].local_id == first.local_id && list[0].name == "First" && list[0].type == "mat", "the first as it was added")
	testing.expect(t, list[1].local_id == second.local_id && list[1].type == "noise", "the second after it")

	engine.scene_sub_asset_rename(tc.scene, first.local_id, "Renamed")
	list = engine.scene_sub_assets(guid)
	testing.expect(t, list[0].name == "Renamed", "a rename reaches the list")

	engine.scene_sub_asset_remove(tc.scene, first.local_id)
	list = engine.scene_sub_assets(guid)
	testing.expect(t, len(list) == 1 && list[0].local_id == second.local_id, "a removal reaches it")
}

// An embedded asset is written inside the field that uses it and read back as
// a new one: the scene file holds its data in the slot, a loader reads it by
// the field's key, and a second load has an embedded asset of its own.
@(test)
test_embedded_asset_is_written_inside_its_field :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "moonhug/tests/fixtures/_test_embedded_asset.scene")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	tH := engine.transform_new("Cube")
	engine.scene_set_root(tc.scene, tH)
	_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
	if !testing.expect(t, mr != nil) do return
	ref, added := engine.embedded_asset_add("mat", `{"color":[0,1,0,1]}`)
	if !testing.expect(t, added && ref.guid == engine.EMBEDDED_ASSETS && ref.local_id != 0, "an embedded asset is made") do return
	append(&mr.materials, ref)
	testing.expect_value(t, len(tc.scene.assets), 0)

	mat, loaded := engine.material_load(engine.asset_key(ref))
	testing.expect(t, loaded && mat.color == {0, 1, 0, 1}, "a loader reads the embedded material")

	testing.expect(t, engine.scene_save(tc.scene, tc.path), "the scene saves")
	text, rerr := os.read_entire_file(tc.path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect(t, strings.contains(string(text), `"embedded": "mat"`), "the slot holds the material's data")
	testing.expect(t, !strings.contains(string(text), `"assets"`), "and the file has no sub-asset for it")

	scene := engine.scene_load_single_path(tc.path)
	if !testing.expect(t, scene != nil, "the scene loads") do return
	_, loaded_mr := engine.transform_get_comp(engine.Transform_Handle(scene.root.handle), engine.MeshRenderer)
	if !testing.expect(t, loaded_mr != nil && len(loaded_mr.materials) == 1) do return
	again := loaded_mr.materials[0]
	testing.expect(t, again.guid == engine.EMBEDDED_ASSETS && again.local_id != ref.local_id, "the loaded slot has an embedded asset of its own")
	mat2, loaded2 := engine.material_load(engine.asset_key(again))
	testing.expect(t, loaded2 && mat2.color == {0, 1, 0, 1}, "with the saved data")

	// An edit of one does not reach the other.
	testing.expect(t, engine.embedded_asset_store(again, `{"color":[0,0,1,1]}`))
	first_text, _ := engine.scene_sub_asset_text(ref)
	testing.expect(t, strings.contains(first_text, "[0,1,0,1]") || strings.contains(first_text, "0,1,0,1"), "the first keeps its data")
}

// An undo snapshot writes an embedded asset with its id, and putting it back
// gives the field the same embedded asset with the snapshot's data. Any other
// text makes a new one, so two fields never share an embedded asset.
@(test)
test_embedded_asset_snapshot_keeps_its_id :: proc(t: ^testing.T) {
	ref, added := engine.embedded_asset_add("mat", `{"color":[0,1,0,1]}`)
	if !testing.expect(t, added) do return

	ser.pptr_embedded_ids = true
	snapshot, merr := json.marshal(ref, allocator = context.temp_allocator)
	ser.pptr_embedded_ids = false
	if !testing.expect(t, merr == nil) do return
	testing.expectf(t, strings.contains(string(snapshot), `"id"`), "the snapshot names the embedded asset, got %s", snapshot)
	plain, _ := json.marshal(ref, allocator = context.temp_allocator)
	testing.expectf(t, !strings.contains(string(plain), `"id"`), "other text does not, got %s", plain)

	testing.expect(t, engine.embedded_asset_store(ref, `{"color":[0,0,1,1]}`))
	back: engine.PPtr
	testing.expect(t, json.unmarshal(snapshot, &back) == nil)
	testing.expect_value(t, back, ref)
	text, _ := engine.scene_sub_asset_text(ref)
	testing.expectf(t, strings.contains(text, "[0,1,0,1]"), "with the snapshot's data, got %s", text)

	copy: engine.PPtr
	testing.expect(t, json.unmarshal(plain, &copy) == nil)
	testing.expectf(t, copy.guid == engine.EMBEDDED_ASSETS && copy.local_id != ref.local_id, "a copy gets an embedded asset of its own")
}

// An export of a scene that uses a material another scene file holds and an
// embedded material that names a texture. The closure ships the other scene
// file and the texture, and leaves out a texture nothing names. With the
// sources gone, the exported scene loads both materials from the export.
@(test)
test_export_ships_sub_assets_and_embedded_assets :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	src_dir :: "moonhug/tests/fixtures/_export_sub_assets_tmp"
	tex :: src_dir + "/tex.png"
	unused :: src_dir + "/unused.png"
	lib :: src_dir + "/lib.scene"
	boot :: src_dir + "/boot.scene"
	data_dir :: src_dir + "_data"
	os.make_directory(src_dir)
	defer {
		_remove_tree(src_dir)
		_remove_tree(data_dir)
		_remove_tree(engine.library_dir())
	}
	png, rerr := os.read_entire_file("moonhug/tests/fixtures/textures/circle-256.png", context.temp_allocator)
	if !testing.expect(t, rerr == nil) do return
	testing.expect(t, os.write_entire_file(tex, png) == nil)
	// One byte more: an artifact of its own, not the referenced one's.
	other := make([]byte, len(png) + 1, context.temp_allocator)
	copy(other, png)
	testing.expect(t, os.write_entire_file(unused, other) == nil)
	// Placeholders: the scan mints the guids the real texts name.
	for p in ([]string{lib, boot}) do testing.expect(t, os.write_entire_file(p, transmute([]byte)string("{}")) == nil)

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	for p in ([]string{tex, unused}) do _ = asset_pipeline.asset_pipeline_import_asset(p)
	tex_raw, tok := engine.asset_db_get_guid(tex)
	unused_raw, uok := engine.asset_db_get_guid(unused)
	lib_raw, lok := engine.asset_db_get_guid(lib)
	boot_raw, bok := engine.asset_db_get_guid(boot)
	if !testing.expect(t, tok && uok && lok && bok, "the scan registers every file") do return
	tex_str := uuid.to_string(tex_raw, context.temp_allocator)
	lib_str := uuid.to_string(lib_raw, context.temp_allocator)

	lib_text := `{
  "root": 1,
  "transforms": [
    {"local_id": 1, "name": "Lib", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": []}
  ],
  "components": [],
  "assets": [{"local_id": 77, "type": "mat", "name": "Green", "data": {"color": [0, 1, 0, 1]}}]
}`
	boot_text := strings.concatenate({`{
  "root": 1,
  "transforms": [
    {"local_id": 1, "name": "Cube", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": [{"local_id": 3}]}
  ],
  "components": [
    {"__type": "`, _MESH_RENDERER_GUID, `",
     "base": {"local_id": 3, "enabled": true},
     "materials": [
       {"local_id": 77, "guid": "`, lib_str, `"},
       {"embedded": "mat", "data": {"color": [0, 0, 1, 1], "texture": "`, tex_str, `"}}
     ]}
  ]
}`}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(lib, transmute([]byte)string(lib_text)) == nil)
	testing.expect(t, os.write_entire_file(boot, transmute([]byte)boot_text) == nil)

	testing.expect(t, catalog.build_to_file("", {src_dir}, engine.library_dir(), engine.asset_catalog_path()), "the catalog builds from the files")
	engine.asset_db_shutdown()
	testing.expect(t, catalog.export_from(engine.asset_catalog_path(), data_dir, boot_scene = boot), "the export succeeds")

	// Only the export is left.
	_remove_tree(src_dir)
	_remove_tree(engine.library_dir())
	testing.expect(t, engine.asset_db_init_from_catalog(data_dir + "/catalog.json"), "the catalog pipeline reads the export")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	_, has_lib := engine.asset_db_get_path(lib_raw)
	_, has_tex := engine.asset_db_get_path(tex_raw)
	_, has_unused := engine.asset_db_get_path(unused_raw)
	testing.expect(t, has_lib, "the scene file that holds the used material ships")
	testing.expect(t, has_tex, "the texture the embedded material names ships")
	testing.expect(t, !has_unused, "a texture nothing names does not ship")

	boot_path, _ := engine.asset_db_get_path(boot_raw)
	scene := engine.scene_load_single_path(boot_path)
	if !testing.expect(t, scene != nil, "the exported scene loads") do return
	tc.scene = scene
	_, mr := engine.transform_get_comp(engine.Transform_Handle(scene.root.handle), engine.MeshRenderer)
	if !testing.expect(t, mr != nil && len(mr.materials) == 2, "with both material slots") do return

	engine.material_cache_init()
	defer engine.material_cache_shutdown()
	green, green_ok := engine.material_load(engine.asset_key(mr.materials[0]))
	testing.expectf(t, green_ok && green.color == {0, 1, 0, 1}, "the other scene's material loads from the export, got %v", green.color)
	testing.expect(t, mr.materials[1].guid == engine.EMBEDDED_ASSETS, "the second slot is embedded")
	blue, blue_ok := engine.material_load(engine.asset_key(mr.materials[1]))
	testing.expectf(t, blue_ok && blue.color == {0, 0, 1, 1}, "the embedded material loads, got %v", blue.color)
	testing.expect(t, blue_ok && blue.texture.guid == engine.Asset_GUID(tex_raw), "and names the shipped texture")
}
