package engine_tests

// Material asset parsing + cache behavior (plugins/engine/docs/Materials.md). Materials are
// GPU-free, so unlike textures/meshes the cache itself is fully testable
// headless.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:testing"
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"

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
	testing.expect(t, mat.shader == .Lit, "default shader is lit")
	testing.expect(t, mat.color == {1, 1, 1, 1}, "default color is white")
	testing.expect(t, mat.lit == engine.MATERIAL_LIT_DEFAULT, "a material without a lit block gets the Lit defaults")
	testing.expect(t, !mat.alpha_clip && mat.alpha_cutoff == engine.MATERIAL_ALPHA_CUTOFF_DEFAULT, "clipping off, the default threshold ready for when it is turned on")
}

// The built-in Lit's block: factors clamped into place, the normal scale
// zeroed without a normal map (white is no normal), the emission color in
// linear. No maps load in a test, so every map slot is empty (white).
@(test)
test_material_pack_lit :: proc(t: ^testing.T) {
	lit := engine.MATERIAL_LIT_DEFAULT
	lit.metallic = 2 // out of range
	lit.smoothness = 0.8
	lit.normal_scale = 1.5
	lit.emission_color = {1, 0.5, 0, 1}
	data, maps := engine._material_pack_lit(&lit)
	testing.expect_value(t, len(data), size_of(gfx.Lit_Material))
	testing.expect_value(t, len(maps), 4)
	block := (^gfx.Lit_Material)(raw_data(data))^
	testing.expect(t, block.params.x == 1 && abs(block.params.y - 0.8) < 1e-6, "metallic clamped, smoothness kept")
	testing.expect(t, block.params.z == 0, "no normal map: scale 0")
	testing.expect(t, block.params.w == 1, "occlusion strength")
	testing.expect(t, block.emission.r == 1 && abs(block.emission.g - 0.2140) < 1e-3 && block.emission.b == 0, "emission decoded to linear")
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
	testing.expect(t, engine._material_equal(loaded, mat), "material should round-trip")
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

// The cutoff a draw passes to gfx: the threshold with clipping on, 0 (nothing
// clipped) with it off, for no material, or for one that does not load.
@(test)
test_material_alpha_cutoff :: proc(t: ^testing.T) {
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	clip_id, _ := uuid.read("21212121-4343-6565-8787-090909090909")
	open_id, _ := uuid.read("31313131-4343-6565-8787-090909090909")
	clip, open := engine.Asset_GUID(clip_id), engine.Asset_GUID(open_id)
	engine.material_preview(clip, {shader = .Lit, color = {1, 1, 1, 1}, alpha_clip = true, alpha_cutoff = 0.3})
	engine.material_preview(open, {shader = .Lit, color = {1, 1, 1, 1}, alpha_clip = false, alpha_cutoff = 0.3})

	testing.expect_value(t, engine.material_alpha_cutoff(clip), f32(0.3))
	testing.expect_value(t, engine.material_alpha_cutoff(open), f32(0))
	testing.expect_value(t, engine.material_alpha_cutoff({}), f32(0))
}

// Property packing: named vec4 values land at the shader's reflected std140
// offsets, truncated to the member size; unmatched names on either side are
// zero-filled / ignored.
@(test)
test_material_pack_properties :: proc(t: ^testing.T) {
	sr := engine.Shader_Runtime{
		block_size = 48,
		properties = []engine.Shader_Property{
			{name = "mix_amount", offset = 0, size = 4},
			{name = "rim_params", offset = 16, size = 16},
			{name = "rimColor", offset = 32, size = 16},
		},
	}
	mat := engine.Material{}
	append(&mat.properties, engine.Material_Property{name = "rim_params", value = {1, 2, 3, 4}})
	append(&mat.properties, engine.Material_Property{name = "mix_amount", value = {0.5, 9, 9, 9}}) // only .x fits a float
	append(&mat.properties, engine.Material_Property{name = "stale_unknown", value = {7, 7, 7, 7}})
	append(&mat.properties, engine.Material_Property{name = "rimColor", value = {1, 0.5, 0, 0.25}})
	defer delete(mat.properties)

	data := engine._material_pack_properties(&mat, &sr)
	testing.expect(t, len(data) == 48, "packed size = block_size")
	floats := ([^]f32)(raw_data(data))[:12]
	testing.expect(t, floats[0] == 0.5, "float lands at offset 0, truncated to 4 bytes")
	testing.expect(t, floats[1] == 0 && floats[2] == 0 && floats[3] == 0, "float padding stays zero")
	testing.expect(t, floats[4] == 1 && floats[7] == 4, "vec4 lands at offset 16, as authored: not a color")
	// A color property (its name says so, any case) goes in as linear light,
	// alpha untouched: sRGB 0.5 is linear 0.214.
	testing.expect(t, floats[8] == 1 && floats[10] == 0 && floats[11] == 0.25, "color ends stay, alpha stays")
	testing.expectf(t, abs(floats[9] - 0.2140) < 0.001, "sRGB 0.5 decodes to 0.214, got %f", floats[9])
}

// Clearing custom_shader purges the property rows (they belong to the
// shader, not the material).
@(test)
test_material_sync_purges_on_shader_clear :: proc(t: ^testing.T) {
	import_strings :: proc(s: string) -> string { // clone helper for owned names
		b := make([]u8, len(s))
		copy(b, s)
		return string(b)
	}
	mat := engine.Material{}
	append(&mat.properties, engine.Material_Property{name = import_strings("old_prop"), value = {1, 2, 3, 4}})
	append(&mat.textures, engine.Material_Texture{name = import_strings("old_tex")})
	defer delete(mat.properties)
	defer delete(mat.textures)

	changed := engine.material_sync_properties(&mat)
	testing.expect(t, changed, "sync should report the purge")
	testing.expect(t, len(mat.properties) == 0, "empty custom_shader should clear all property rows")
	testing.expect(t, len(mat.textures) == 0, "empty custom_shader should clear all texture rows")

	changed = engine.material_sync_properties(&mat)
	testing.expect(t, !changed, "second sync is a no-op")
}

@(test)
test_material_shader_names :: proc(t: ^testing.T) {
	testing.expect(t, engine.material_shader_name(.Unlit) == "unlit", "unlit maps to gfx name")
	testing.expect(t, engine.material_shader_name(.Lit) == "lit", "lit maps to gfx name")
}

// The cache outlives every caller: a preview pushed from a frame whose
// context.allocator is the temp allocator must not leave temp-owned strings
// in the cache, or the next preview's cleanup frees them with the wrong
// allocator (the "Bad free" crash when tweaking a material's properties).
@(test)
test_material_cache_pins_its_allocator :: proc(t: ^testing.T) {
	engine.material_cache_init()
	defer engine.material_cache_shutdown()

	guid_id, _ := uuid.read("13131313-3434-5656-7878-909090909090")
	guid := engine.Asset_GUID(guid_id)

	{
		context.allocator = context.temp_allocator
		props := make([dynamic]engine.Material_Property, context.temp_allocator)
		append(&props, engine.Material_Property{name = "rim_power", value = {3, 0, 0, 0}})
		engine.material_preview(guid, {shader = .Lit, properties = props})
	}
	free_all(context.temp_allocator) // the frame ends, the temp strings are gone

	mat, ok := engine.material_load(guid)
	testing.expect(t, ok, "previewed material should be a cache hit")
	if !ok do return
	testing.expect(t, len(mat.properties) == 1 && mat.properties[0].name == "rim_power", "the cache keeps its own copy of the names")

	// A changed value replaces the entry: frees the old names with the cache's allocator.
	engine.material_preview(guid, {shader = .Lit, color = {0, 1, 0, 1}})
	mat, ok = engine.material_load(guid)
	testing.expect(t, ok && mat.color == {0, 1, 0, 1}, "the new preview sticks")
}
