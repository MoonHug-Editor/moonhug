package engine_tests

// Named layers (plugins/engine/docs/Layers.md): the per-domain name registry,
// the Render Layers asset and how the Layers setting's choice of it reaches
// the "render" domain, and the layer picker's closed text. Also the load rule the layer masks depend on: a field
// missing from a file loads as the type's reset default (Components.md).

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor/inspector"
import asset_pipeline "moonhug:editor/assets"
import core "moonhug:libs/core"
import "moonhug:libs/serialization"

@(private = "file")
_test_layer_names := [engine.LAYER_COUNT]string{0 = "Ground", 3 = "Water"}

@(test)
test_layer_registry :: proc(t: ^testing.T) {
	engine.layer_domain_register("test_layers", &_test_layer_names, hidden = 1 << 7)

	names := engine.layer_names("test_layers")
	testing.expect(t, names == &_test_layer_names, "the registry hands out the owner's own list")
	testing.expect_value(t, engine.layer_name("test_layers", 3), "Water")
	testing.expect_value(t, engine.layer_name("test_layers", 1), "")
	testing.expect_value(t, engine.layer_name("test_layers", 40), "")
	testing.expect_value(t, engine.layer_index("test_layers", "Ground"), 0)
	testing.expect_value(t, engine.layer_index("test_layers", "Lava"), -1)
	testing.expect_value(t, engine.layer_hidden_mask("test_layers"), u32(1 << 7))

	// An edit to the owner's list is what readers see next: no copy to sync.
	_test_layer_names[5] = "Glass"
	defer _test_layer_names[5] = ""
	testing.expect_value(t, engine.layer_index("test_layers", "Glass"), 5)

	// Registering the same list again is allowed.
	engine.layer_domain_register("test_layers", &_test_layer_names, hidden = 1 << 7)

	testing.expect(t, engine.layer_names("no_such_domain") == nil, "an unknown domain has no names")
	testing.expect_value(t, engine.layer_name("no_such_domain", 0), "")

	// A domain with a refresh proc brings its names up to date before every
	// read.
	engine.layer_domain_register("test_layers_refresh", &_test_refreshed_names, refresh = proc() {
		_test_refreshes += 1
		_test_refreshed_names[2] = "Fresh"
	})
	testing.expect_value(t, engine.layer_name("test_layers_refresh", 2), "Fresh")
	before := _test_refreshes
	_ = engine.layer_names("test_layers_refresh")
	testing.expect_value(t, _test_refreshes, before + 1)
}

@(private = "file") _test_refreshed_names: [engine.LAYER_COUNT]string
@(private = "file") _test_refreshes: int

// A new Render Layers asset names layer 0 "Default" and layer 31 "Editor", and
// nothing else.
@(test)
test_layers_assets_reset_defaults :: proc(t: ^testing.T) {
	r: engine.Render_Layers
	engine.reset_Render_Layers(&r)
	defer engine.cleanup_Render_Layers(&r)
	_expect_default_render(t, r)
}

// A Render Layers file loads over the reset defaults: names the file lacks
// keep the default. A file of another type, or a malformed one, does not load.
@(test)
test_layers_assets_parse :: proc(t: ^testing.T) {
	render_json := `{
		"__type_guid": "61bc7a2f-3326-4f13-b233-7bccf12f709e",
		"names": ["Default", "Water", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "Editor"]
	}`
	r, rok := engine.asset_parse_as(transmute([]byte)string(render_json), engine.Render_Layers)
	defer engine.cleanup_Render_Layers(&r)
	testing.expect(t, rok, "the render file parses")
	testing.expect_value(t, r.names[1], "Water")
	testing.expect_value(t, r.names[engine.RENDER_LAYER_EDITOR], "Editor")

	sparse, sok := engine.asset_parse_as(transmute([]byte)string(`{"__type_guid": "61bc7a2f-3326-4f13-b233-7bccf12f709e"}`), engine.Render_Layers)
	defer engine.cleanup_Render_Layers(&sparse)
	testing.expect(t, sok, "a file without names parses")
	_expect_default_render(t, sparse)

	_, wrong := engine.asset_parse_as(transmute([]byte)string(`{"__type_guid": "6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e1ff", "names": []}`), engine.Render_Layers)
	testing.expect(t, !wrong, "a file of another type does not load as Render Layers")
	_, bad := engine.asset_parse_as(transmute([]byte)string(`{"__type_guid": "61bc7a2f-3326-4f13-b233-7bccf12f709e", "names": 5}`), engine.Render_Layers)
	testing.expect(t, !bad, "a malformed file does not load")
}

// The essentials plugin's default asset holds the reset defaults and carries
// the guid the plugin installs. Skipped when the essentials plugin is not
// installed.
@(test)
test_shipped_default_layers :: proc(t: ^testing.T) {
	render_path :: "plugins/essentials/assets/rendering/DefaultRenderLayers.asset"
	if !os.exists(render_path) do return
	r, rok := engine.layers_load_file(render_path)
	defer engine.cleanup_Render_Layers(&r)
	testing.expect(t, rok, "DefaultRenderLayers.asset loads")
	_expect_default_render(t, r)
	testing.expect(t, _meta_guid(render_path + ".meta") == "df291cbd-037a-46f5-bad4-f27e885029c0", "the render default keeps its guid")
}

@(private = "file")
_meta_guid :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	m: struct { guid: string }
	if json.unmarshal(data, &m, allocator = context.temp_allocator) != nil do return ""
	return m.guid
}

@(private = "file")
_LAYERS_DIR :: "moonhug/tests/fixtures/_layers_tmp"
@(private = "file")
_RENDER_A_GUID :: "6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e1a1"
@(private = "file")
_RENDER_B_GUID :: "6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e1b2"

@(private = "file")
_write_render :: proc(t: ^testing.T, path, guid, name1: string) {
	l: engine.Render_Layers
	engine.reset_Render_Layers(&l)
	defer engine.cleanup_Render_Layers(&l)
	l.names[1] = strings.clone(name1)
	testing.expect(t, serialization.write_asset_to_path(path, engine.get_guid_by_typeid(engine.Render_Layers), l))
	_write_meta(t, path, guid)
}

@(private = "file")
_write_meta :: proc(t: ^testing.T, path, guid: string) {
	if guid == "" do return
	meta := fmt.tprintf(`{{"guid": "%s"}}`, guid)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s.meta", path), meta) == nil)
}

@(private = "file")
_guid :: proc(s: string) -> engine.Asset_GUID {
	id, _ := uuid.read(s)
	return engine.Asset_GUID(id)
}

// The Layers setting picks the Render Layers asset. The "render" domain shows
// its names, follows a switch to another asset, a change of the file on disk
// and an inspector edit of the active asset's document, and keeps the same
// registered list throughout.
@(test)
test_layers_follow_layers_setting :: proc(t: ^testing.T) {
	os.make_directory(_LAYERS_DIR)
	defer {
		_remove_tree(_LAYERS_DIR)
		_remove_tree("library")
	}
	engine.layers_sync()
	render_list := engine.layer_names(engine.LAYER_DOMAIN_RENDER)
	testing.expect(t, render_list != nil, "the engine registers the render domain")
	testing.expect_value(t, engine.layer_hidden_mask(engine.LAYER_DOMAIN_RENDER), u32(1) << engine.RENDER_LAYER_EDITOR)

	_write_render(t, _LAYERS_DIR + "/RenderA.asset", _RENDER_A_GUID, "Water")
	_write_render(t, _LAYERS_DIR + "/RenderB.asset", _RENDER_B_GUID, "Glass")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_LAYERS_DIR)
	asset_pipeline.asset_db_refresh()
	prev := engine.layers_settings
	defer {
		engine.layers_settings = prev
		engine.asset_db_shutdown()
		engine.layers_sync()
		testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 1), "")
	}
	render_a, render_b := _guid(_RENDER_A_GUID), _guid(_RENDER_B_GUID)

	// The type index lists each asset under its own type: what a
	// `ref:"Render_Layers"` field's picker offers.
	render_key, _ := core.get_type_key_by_typeid(engine.Render_Layers)
	_expect_indexed(t, render_key, {render_a, render_b})

	engine.layers_settings = {render_layers = render_a}
	engine.layers_sync()
	testing.expect_value(t, engine.layers_active_guid(), render_a)
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 1), "Water")
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, engine.RENDER_LAYER_EDITOR), "Editor")

	engine.layers_settings = {render_layers = render_b}
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 1), "Glass") // the read refreshes
	testing.expect(t, engine.layer_names(engine.LAYER_DOMAIN_RENDER) == render_list, "a switch keeps the registered render list")

	// A file changes on disk: the next sync reads it again.
	_write_render(t, _LAYERS_DIR + "/RenderB.asset", "", "Glass Wall")
	asset_pipeline.asset_db_refresh()
	engine.layers_sync()
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 1), "Glass Wall")

	// An inspector edit of the active asset reaches the picker, an edit of
	// another asset does not.
	edit: engine.Render_Layers
	engine.reset_Render_Layers(&edit)
	defer engine.cleanup_Render_Layers(&edit)
	edit.names[2] = strings.clone("UI")
	engine.render_layers_preview(render_a, edit)
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 2), "")
	engine.render_layers_preview(render_b, edit)
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 2), "UI")

	// A setting naming no asset in the project falls back to the built-in
	// names.
	engine.layers_settings = {render_layers = _guid("6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e1c3")}
	engine.layers_sync()
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 2), "")
	testing.expect_value(t, engine.layer_name(engine.LAYER_DOMAIN_RENDER, 0), "Default")
}

@(private = "file")
_expect_indexed :: proc(t: ^testing.T, key: core.TypeKey, want: []engine.Asset_GUID) {
	got := engine.asset_db_assets_with_root_type(key)
	testing.expectf(t, len(got) == len(want), "%v lists %d assets, got %d", key, len(want), len(got))
	for g in want {
		found := false
		for e in got do if e.guid == g do found = true
		testing.expectf(t, found, "%v lists %v", key, g)
	}
}

@(private = "file")
_expect_default_render :: proc(t: ^testing.T, l: engine.Render_Layers) {
	for name, i in l.names {
		switch i {
		case engine.RENDER_LAYER_DEFAULT: testing.expect_value(t, name, "Default")
		case engine.RENDER_LAYER_EDITOR:  testing.expect_value(t, name, "Editor")
		case: testing.expectf(t, name == "", "render layer %d starts unnamed, got %q", i, name)
		}
	}
}

@(test)
test_layer_mask_preview :: proc(t: ^testing.T) {
	names := [engine.LAYER_COUNT]string{0 = "Default", 1 = "Water", 2 = "UI", 3 = "FX", 31 = "Editor"}
	hidden := u32(1) << 31

	testing.expect_value(t, inspector.layer_mask_preview(0, &names, hidden), "Nothing")
	testing.expect_value(t, inspector.layer_mask_preview(1 << 31, &names, hidden), "Nothing")
	testing.expect_value(t, inspector.layer_mask_preview(0xFFFFFFFF, &names, hidden), "Everything")
	testing.expect_value(t, inspector.layer_mask_preview(0x7FFFFFFF, &names, hidden), "Everything")
	testing.expect_value(t, inspector.layer_mask_preview(1 << 1, &names, hidden), "Water")
	testing.expect_value(t, inspector.layer_mask_preview(0b111, &names, hidden), "Default, Water, UI")
	testing.expect_value(t, inspector.layer_mask_preview(0b1111, &names, hidden), "Mixed")
	// A bit with no name cannot be listed.
	testing.expect_value(t, inspector.layer_mask_preview(1 << 9, &names, hidden), "Mixed")
}

CAMERA_GUID :: "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"
REFLECTION_PROBE_GUID :: "8909eabd-746b-4bfd-b405-e3a34003d0b9"

// The scene the two tests below load: a Camera and a Reflection_Probe saved
// before render_layer_mask, diffuse and culling_mask existed.
@(private = "file")
_load_scene_without_new_fields :: proc(t: ^testing.T, tc_mem: ^TestCtx) -> engine.Transform_Handle {
	scene_json := `{
		"root": 1,
		"transforms": [
			{"local_id": 1, "name": "Root", "is_active": true,
			 "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
			 "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
			 "children": [], "components": [{"local_id": 5}, {"local_id": 6}]}
		],
		"nested_scenes": [], "breadcrumbs": [],
		"components": [
			{"__type": "` + CAMERA_GUID + `", "base": {"local_id": 5, "enabled": true}, "fov": 45},
			{"__type": "` + REFLECTION_PROBE_GUID + `", "base": {"local_id": 6, "enabled": true}, "intensity": 2}
		]
	}`
	werr := os.write_entire_file(tc_mem.path, transmute([]byte)scene_json)
	testing.expect(t, werr == nil, "fixture write should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene should load")
	if loaded == nil do return {}
	tc_mem.scene = loaded
	return engine.Transform_Handle(loaded.root.handle)
}

// A component saved before a field existed loads that field as its reset
// default, not zero: a Camera without render_layer_mask still draws every
// layer, a Reflection_Probe without diffuse or culling_mask still lights
// diffusely and captures every layer.
@(test)
test_loaded_component_keeps_reset_defaults :: proc(t: ^testing.T) {
	prev := core.serialization_settings.load_defaults_for_missing_fields
	core.serialization_settings.load_defaults_for_missing_fields = true
	defer core.serialization_settings.load_defaults_for_missing_fields = prev

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_reset_defaults.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	root := _load_scene_without_new_fields(t, tc_mem)
	if root == {} do return

	_, cam := engine.transform_get_comp(root, engine.Camera)
	testing.expect(t, cam != nil, "Camera should load")
	if cam != nil {
		testing.expect_value(t, cam.fov, f32(45))
		testing.expect_value(t, cam.render_layer_mask, u32(0xFFFFFFFF))
		testing.expect_value(t, cam.far_clip, f32(1000))
		testing.expect(t, cam.enabled, "the file's own base fields win")
	}

	_, probe := engine.transform_get_comp(root, engine.Reflection_Probe)
	testing.expect(t, probe != nil, "Reflection_Probe should load")
	if probe != nil {
		testing.expect_value(t, probe.intensity, f32(2))
		testing.expect(t, probe.diffuse, "a missing diffuse loads as its reset default, on")
		testing.expect_value(t, probe.culling_mask, u32(0xFFFFFFFF))
	}
}

// With the Serialization setting off, a field missing from the file loads as
// zero: the load is a plain unmarshal.
@(test)
test_loaded_component_zero_with_defaults_off :: proc(t: ^testing.T) {
	prev := core.serialization_settings.load_defaults_for_missing_fields
	core.serialization_settings.load_defaults_for_missing_fields = false
	defer core.serialization_settings.load_defaults_for_missing_fields = prev

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_reset_defaults_off.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	root := _load_scene_without_new_fields(t, tc_mem)
	if root == {} do return

	_, cam := engine.transform_get_comp(root, engine.Camera)
	testing.expect(t, cam != nil, "Camera should load")
	if cam != nil {
		testing.expect_value(t, cam.fov, f32(45))
		testing.expect_value(t, cam.render_layer_mask, u32(0))
	}

	_, probe := engine.transform_get_comp(root, engine.Reflection_Probe)
	testing.expect(t, probe != nil, "Reflection_Probe should load")
	if probe != nil {
		testing.expect(t, !probe.diffuse, "a missing diffuse loads as zero, off")
		testing.expect_value(t, probe.culling_mask, u32(0))
	}
}

// A reset that allocates: the defaults of the fields the data supplies are
// freed, the defaults of the missing ones move into the value. The test's
// tracking allocator reports anything left behind.
@(test)
test_unmarshal_over_reset_frees_replaced_defaults :: proc(t: ^testing.T) {
	data := `{"steps": [], "next_id": 5}`
	p: engine.Render_Pipeline
	err := engine.unmarshal_over_reset(transmute([]byte)data, &p, typeid_of(engine.Render_Pipeline))
	defer engine.cleanup_Render_Pipeline(&p)
	testing.expect(t, err == nil, "unmarshal should succeed")
	testing.expect_value(t, len(p.steps), 0)
	testing.expect_value(t, p.next_id, i32(5))
	testing.expect_value(t, len(p.slots), 1)
	if len(p.slots) == 1 do testing.expect_value(t, p.slots[0].name, engine.MAIN_SLOT)
}

// Undo, revert and paste write a whole field back through its pointer type:
// the layer assets' 32 names and the collision matrix's 32 rows have one.
@(test)
test_layer_arrays_write_back :: proc(t: ^testing.T) {
	serialization.register_component_serializers()
	_, names_ok := core.get_pointer_typeid_by_typeid([core.LAYER_COUNT]string)
	_, rows_ok := core.get_pointer_typeid_by_typeid([core.LAYER_COUNT]u32)
	testing.expect(t, names_ok, "[32]string has a pointer type")
	testing.expect(t, rows_ok, "[32]u32 has a pointer type")
}
