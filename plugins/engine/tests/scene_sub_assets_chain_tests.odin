package engine_tests

// Sub-assets and embedded assets through a prefab chain. inner.scene holds a
// MeshRenderer with a material of its own file (record 77) and an embedded
// material. middle.scene nests inner, mid_Variant is a variant of middle, and
// host.scene nests mid_Variant: three levels between the host and the
// renderer. Each level's references must still name inner's record, and each
// embedded material must load.

import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine"

@(private = "file")
_INNER :: `{
  "root": 1,
  "transforms": [
    {"local_id": 1, "name": "Inner", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": [{"local_id": 3}]}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "73e161a0-c599-4cfb-9826-447e05baa76c",
     "base": {"local_id": 3, "enabled": true},
     "materials": [
       {"local_id": 77, "guid": "00000000-0000-0000-0000-000000000000"},
       {"embedded": "mat", "data": {"color": [0, 0, 1, 1]}}
     ]}
  ],
  "assets": [{"local_id": 77, "type": "mat", "name": "Green", "data": {"color": [0, 1, 0, 1]}}]
}`

@(private = "file")
_Chain :: struct {
	dir:                         string,
	inner, middle, variant, host: string,
	inner_guid, variant_guid:    engine.Asset_GUID,
}

@(private = "file")
_chain_author :: proc(t: ^testing.T, tc: ^TestCtx, dir: string) -> (c: _Chain, ok: bool) {
	c.dir = dir
	c.inner = strings.concatenate({dir, "/inner.scene"}, context.temp_allocator)
	c.middle = strings.concatenate({dir, "/middle.scene"}, context.temp_allocator)
	c.variant = strings.concatenate({dir, "/mid_Variant.scene"}, context.temp_allocator)
	c.host = strings.concatenate({dir, "/host.scene"}, context.temp_allocator)
	os.make_directory(dir)
	if !testing.expect(t, os.write_entire_file(c.inner, transmute([]byte)string(_INNER)) == nil) do return
	engine.asset_db_init(dir)
	asset_pipeline.asset_db_refresh()
	raw, known := engine.asset_db_get_guid(c.inner)
	if !testing.expect(t, known, "inner is in the asset db") do return
	c.inner_guid = engine.Asset_GUID(raw)

	// middle: the bootstrap scene with inner nested, saved.
	if !testing.expect(t, engine.scene_instantiate_guid_nested(c.inner_guid, engine.Transform_Handle(tc.scene.root.handle)) != {}, "inner nests into middle") do return
	if !testing.expect(t, engine.scene_save(tc.scene, c.middle), "middle saves") do return
	asset_pipeline.asset_db_refresh()
	if !testing.expect(t, engine.scene_create_variant_file(c.middle, c.variant), "the variant is made") do return
	asset_pipeline.asset_db_refresh()
	vraw, vknown := engine.asset_db_get_guid(c.variant)
	if !testing.expect(t, vknown, "the variant is in the asset db") do return
	c.variant_guid = engine.Asset_GUID(vraw)

	if !testing.expect(t, fixture_write_empty_scene(c.host, "Host")) do return
	asset_pipeline.asset_db_refresh()
	return c, true
}

// The MeshRenderers of `s`, its nested content included.
@(private = "file")
_renderers :: proc(tc: ^TestCtx, s: ^engine.Scene) -> [dynamic]^engine.MeshRenderer {
	out := make([dynamic]^engine.MeshRenderer, context.temp_allocator)
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		th := ih
		th.type_key = .Transform
		_, mr := engine.transform_get_comp(engine.Transform_Handle(th), engine.MeshRenderer)
		if mr != nil do append(&out, mr)
	}
	return out
}

@(private = "file")
_color_of :: proc(ref: engine.PPtr) -> (color: [4]f32, ok: bool) {
	engine.material_unload(engine.asset_key(ref))
	mat, loaded := engine.material_load(engine.asset_key(ref))
	if !loaded do return {}, false
	return mat.color, true
}

// Nested three levels deep (host > variant > middle > inner), the inner
// file's record and embedded material both load, in every copy.
@(test)
test_sub_assets_load_through_nested_prefab_and_variant :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()
	dir :: "moonhug/tests/fixtures/_sub_assets_chain_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	c, ok := _chain_author(t, tc, dir)
	if !ok do return
	want := engine.PPtr{guid = c.inner_guid, local_id = 77}

	host := engine.scene_load(c.host)
	if !testing.expect(t, host != nil, "host loads") do return
	tc.scene = host
	engine.sm_scene_set_active(host)
	root := engine.Transform_Handle(host.root.handle)
	testing.expect(t, engine.scene_instantiate_guid_nested(c.variant_guid, root) != {}, "the variant nests into host")
	testing.expect(t, engine.scene_instantiate_guid_nested(c.variant_guid, root) != {}, "twice")

	check :: proc(t: ^testing.T, tc: ^TestCtx, s: ^engine.Scene, want: engine.PPtr, copies: int, what: string) {
		mrs := _renderers(tc, s)
		testing.expectf(t, len(mrs) == copies, "%s: %d renderers, got %d", what, copies, len(mrs))
		embedded_ids: [dynamic]engine.Local_ID
		embedded_ids.allocator = context.temp_allocator
		for mr in mrs {
			if !testing.expectf(t, len(mr.materials) == 2, "%s: both slots load", what) do continue
			testing.expectf(t, mr.materials[0] == want, "%s: slot 0 names inner's record, got %v", what, mr.materials[0])
			col, loaded := _color_of(mr.materials[0])
			testing.expectf(t, loaded && col == {0, 1, 0, 1}, "%s: inner's record loads green, got %v", what, col)
			e := mr.materials[1]
			testing.expectf(t, e.guid == engine.EMBEDDED_ASSETS, "%s: slot 1 is embedded, got %v", what, e)
			col, loaded = _color_of(e)
			testing.expectf(t, loaded && col == {0, 0, 1, 1}, "%s: the embedded material loads blue, got %v", what, col)
			for id in embedded_ids do testing.expectf(t, id != e.local_id, "%s: each copy has an embedded material of its own", what)
			append(&embedded_ids, e.local_id)
		}
	}
	check(t, tc, host, want, 2, "host")

	// Saved and loaded again.
	testing.expect(t, engine.scene_save(host, c.host), "host saves")
	again := engine.scene_load(c.host)
	if !testing.expect(t, again != nil, "host loads again") do return
	tc.scene = again
	check(t, tc, again, want, 2, "host reloaded")

	// The variant opened by itself.
	v := engine.scene_load(c.variant)
	if !testing.expect(t, v != nil, "the variant opens") do return
	tc.scene = v
	check(t, tc, v, want, 1, "variant")
}

// The variant changes both slots: slot 0 to a record of its own file, slot 1
// to an embedded material of its own. Both are overrides the variant saves,
// and a host that nests the variant gets them.
@(test)
test_variant_overrides_name_its_own_sub_asset_and_embedded_asset :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()
	dir :: "moonhug/tests/fixtures/_sub_assets_variant_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	c, ok := _chain_author(t, tc, dir)
	if !ok do return

	v := engine.scene_load(c.variant)
	if !testing.expect(t, v != nil, "the variant opens") do return
	tc.scene = v
	engine.sm_scene_set_active(v)
	mrs := _renderers(tc, v)
	if !testing.expect(t, len(mrs) == 1 && len(mrs[0].materials) == 2) do return
	own, added := engine.scene_sub_asset_add(v, "mat", `{"color":[1,1,0,1]}`, "Yellow")
	if !testing.expect(t, added, "the variant gets a record") do return
	red, made := engine.embedded_asset_add("mat", `{"color":[1,0,0,1]}`)
	if !testing.expect(t, made) do return
	mrs[0].materials[0] = own
	mrs[0].materials[1] = red
	testing.expect(t, engine.scene_save(v, c.variant), "the variant saves")
	text, _ := os.read_entire_file(c.variant, context.temp_allocator)
	testing.expectf(t, len(text) > 0, "the variant file is written")

	host := engine.scene_load(c.host)
	if !testing.expect(t, host != nil, "host loads") do return
	tc.scene = host
	engine.sm_scene_set_active(host)
	testing.expect(t, engine.scene_instantiate_guid_nested(c.variant_guid, engine.Transform_Handle(host.root.handle)) != {}, "the variant nests into host")
	hm := _renderers(tc, host)
	if !testing.expect(t, len(hm) == 1 && len(hm[0].materials) == 2, "host has the renderer") do return
	want := engine.PPtr{guid = c.variant_guid, local_id = own.local_id}
	testing.expectf(t, hm[0].materials[0] == want, "slot 0 names the variant's record, got %v (variant %s)", hm[0].materials[0], uuid.to_string(uuid.Identifier(c.variant_guid), context.temp_allocator))
	col, loaded := _color_of(hm[0].materials[0])
	testing.expectf(t, loaded && col == {1, 1, 0, 1}, "the variant's record loads yellow, got %v", col)
	e := hm[0].materials[1]
	testing.expectf(t, e.guid == engine.EMBEDDED_ASSETS && e.local_id != red.local_id, "slot 1 is an embedded material of the host's copy, got %v", e)
	col, loaded = _color_of(e)
	testing.expectf(t, loaded && col == {1, 0, 0, 1}, "the variant's embedded material loads red, got %v", col)
}

// A variant made directly of inner, whose own renderer uses inner's record.
// Nested in a host, the variant's content is inner's content: slot 0 still
// names inner's file, not the variant's.
@(test)
test_variant_of_a_prefab_keeps_the_base_files_sub_asset :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()
	dir :: "moonhug/tests/fixtures/_sub_assets_base_variant_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	c, ok := _chain_author(t, tc, dir)
	if !ok do return
	iv := strings.concatenate({dir, "/inner_Variant.scene"}, context.temp_allocator)
	if !testing.expect(t, engine.scene_create_variant_file(c.inner, iv), "the variant of inner is made") do return
	asset_pipeline.asset_db_refresh()
	raw, known := engine.asset_db_get_guid(iv)
	if !testing.expect(t, known) do return
	iv_guid := engine.Asset_GUID(raw)
	want := engine.PPtr{guid = c.inner_guid, local_id = 77}

	for pass in 0 ..< 2 {
		what := pass == 0 ? "opened" : "nested"
		s: ^engine.Scene
		if pass == 0 {
			s = engine.scene_load(iv)
		} else {
			s = engine.scene_load(c.host)
			if s != nil do testing.expect(t, engine.scene_instantiate_guid_nested(iv_guid, engine.Transform_Handle(s.root.handle)) != {}, "the variant nests into host")
		}
		if !testing.expectf(t, s != nil, "%s: loads", what) do return
		tc.scene = s
		engine.sm_scene_set_active(s)
		mrs := _renderers(tc, s)
		if !testing.expectf(t, len(mrs) == 1 && len(mrs[0].materials) == 2, "%s: the renderer is there", what) do continue
		testing.expectf(t, mrs[0].materials[0] == want, "%s: slot 0 names inner's record, got %v", what, mrs[0].materials[0])
		col, loaded := _color_of(mrs[0].materials[0])
		testing.expectf(t, loaded && col == {0, 1, 0, 1}, "%s: it loads green, got %v", what, col)
		col, loaded = _color_of(mrs[0].materials[1])
		testing.expectf(t, loaded && col == {0, 0, 1, 1}, "%s: the embedded material loads blue, got %v", what, col)
	}
}

// The `materials` overrides in the scene file at `path`.
@(private = "file")
_materials_overrides :: proc(t: ^testing.T, path: string) -> int {
	sf, ok := engine.scene_file_load(path)
	if !testing.expectf(t, ok, "%s parses", path) do return -1
	defer engine.scene_file_destroy(&sf)
	n := 0
	for ns in sf.nested_scenes {
		for ov in ns.overrides do if ov.property_path == "materials" do n += 1
	}
	return n
}

// A prefab's reference to a record of its own file is not an override of an
// untouched instance: saving the host, and a host of a variant of it, writes
// none. A slot the host changes is still one.
@(test)
test_untouched_instance_saves_no_override_for_the_prefabs_own_sub_asset :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.material_cache_init()
	defer engine.material_cache_shutdown()
	dir :: "moonhug/tests/fixtures/_sub_assets_no_override_tmp"
	defer _remove_tree(dir)
	defer engine.scene_lib_shutdown()
	defer engine.asset_db_shutdown()
	c, ok := _chain_author(t, tc, dir)
	if !ok do return
	testing.expectf(t, _materials_overrides(t, c.middle) == 0, "middle, which nests inner untouched, has no materials override")

	host := engine.scene_load(c.host)
	if !testing.expect(t, host != nil, "host loads") do return
	tc.scene = host
	engine.sm_scene_set_active(host)
	testing.expect(t, engine.scene_instantiate_guid_nested(c.variant_guid, engine.Transform_Handle(host.root.handle)) != {}, "the variant nests into host")
	if !testing.expect(t, engine.scene_save(host, c.host), "host saves") do return
	testing.expectf(t, _materials_overrides(t, c.host) == 0, "host, which nests the variant untouched, has no materials override")

	// A changed slot is an override.
	mrs := _renderers(tc, host)
	if !testing.expect(t, len(mrs) == 1) do return
	mrs[0].materials[0] = {}
	if !testing.expect(t, engine.scene_save(host, c.host), "host saves again") do return
	testing.expectf(t, _materials_overrides(t, c.host) == 1, "a cleared slot is one materials override")
}
