package tests

// Material asset parsing + cache behavior (docs/Materials.md). Materials are
// GPU-free, so unlike textures/meshes the cache itself is fully testable
// headless.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:testing"
import "../engine"

// The exact shape write_asset_to_path produces: __type_guid first, then the
// marshaled fields. The unknown key must be tolerated.
@(test)
test_material_parse_file_shape :: proc(t: ^testing.T) {
	data := `{
  "__type_guid": "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4",
  "shader": 1,
  "color": [0.25, 0.5, 0.75, 1.0]
}`
	mat, ok := engine._material_parse(transmute([]u8)data)
	testing.expect(t, ok, "material file shape should parse")
	testing.expect(t, mat.shader == .Lit, "shader should parse")
	testing.expect(t, mat.color == {0.25, 0.5, 0.75, 1}, "color should parse")
	testing.expect(t, mat.texture == {}, "absent texture stays empty")
}

// Fields absent from the file (older assets after Material grows) keep sane
// defaults instead of zeroes — a color-less material must not render black.
@(test)
test_material_parse_defaults :: proc(t: ^testing.T) {
	data := `{}`
	mat, ok := engine._material_parse(transmute([]u8)data)
	testing.expect(t, ok, "empty object should parse")
	testing.expect(t, mat.shader == .Unlit, "default shader is unlit")
	testing.expect(t, mat.color == {1, 1, 1, 1}, "default color is white")
}

@(test)
test_material_marshal_roundtrip :: proc(t: ^testing.T) {
	tex_guid, _ := uuid.read("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	mat := engine.Material{
		shader  = .Lit,
		texture = engine.Asset_GUID(tex_guid),
		color   = {0.1, 0.2, 0.3, 0.4},
	}
	data, err := json.marshal(mat, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil, "material should marshal")

	loaded, ok := engine._material_parse(data)
	testing.expect(t, ok, "marshaled material should parse back")
	testing.expect(t, loaded == mat, "material should round-trip")
}

@(test)
test_material_cache_preview_and_unload :: proc(t: ^testing.T) {
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	guid_id, _ := uuid.read("12121212-3434-5656-7878-909090909090")
	guid := engine.Asset_GUID(guid_id)

	engine.material_preview(guid, {shader = .Lit, color = {1, 0, 0, 1}})
	mat, ok := engine.material_load(guid)
	testing.expect(t, ok, "previewed material should be a cache hit")
	if !ok do return
	testing.expect(t, mat.shader == .Lit && mat.color == {1, 0, 0, 1}, "preview values should stick")

	engine.material_unload(guid)
	_, still := engine.material_load(guid) // no asset_db in this test → miss
	testing.expect(t, !still, "unloaded material without a backing file should miss")
}

@(test)
test_material_shader_names :: proc(t: ^testing.T) {
	testing.expect(t, engine.material_shader_name(.Unlit) == "unlit", "unlit maps to gfx name")
	testing.expect(t, engine.material_shader_name(.Lit) == "lit", "lit maps to gfx name")
}
